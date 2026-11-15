import datetime as dt

import pytest

from bot.nemo import memberguards, reactivation

ENDS = dt.datetime(2026, 11, 22, tzinfo=dt.UTC)
NOW = dt.datetime(2026, 11, 15, 13, 0, tzinfo=dt.UTC)


class Conn:
    def __init__(self, guard=None, deactivated=True, bans=(), recorded=(90,), latest=None):
        self.answers = {
            reactivation.STANDING: [guard] if guard else [],
            reactivation.DEACTIVATED: [(deactivated,)],
            reactivation.RUNNING_BANS: list(bans),
            reactivation.RECORD: [recorded] if recorded else [],
            reactivation.LATEST_BAN: [latest] if latest else [],
            reactivation.END_BAN: [(NOW,)],
        }
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        self.last = sql
        return self

    def fetchone(self):
        rows = self.answers.get(self.last, [])
        return rows[0] if rows else None

    def fetchall(self):
        return self.answers.get(self.last, [])

    def ran(self, sql):
        return [args for statement, args in self.executed if statement == sql]

    def audits(self):
        return [(args[2], args[3], args[4]) for sql, args in self.executed if "INSERT INTO fd.audit" in sql]


@pytest.fixture
def lifts(monkeypatch):
    seen = []
    monkeypatch.setattr(memberguards, "lift", lambda conn, guard_id, by, why, kind=None: seen.append((guard_id, kind)) or True)
    return seen


def test_account_bans_are_the_deactivating_types():
    assert reactivation.account_bans() == ["temp_ban", "indef_ban", "perma_ban"]


def test_nemo_guard_is_lifted_through_slack_and_running_bans_end(lifts):
    conn = Conn(guard=(7, "nemo", "live"), bans=[(41, None), (42, ENDS)])

    assert reactivation.reactivate(conn, "U1", "UMOD", "appeal accepted") == ("queued", [41, 42])

    assert lifts == [(7, "deactivation")]
    assert conn.ran(reactivation.END_BAN) == [(41,), (42,)]
    assert conn.audits() == [("action", 41, "ended"), ("action", 42, "ended")]


def test_deactivated_account_without_a_guard_gets_one_recorded_then_lifted(lifts):
    conn = Conn(guard=None)

    assert reactivation.reactivate(conn, "U1", "UMOD", "appeal accepted") == ("queued", [])

    assert conn.ran(reactivation.RECORD) == [("U1", "UMOD", None, "Deactivated outside Nemo", None)]
    assert conn.audits() == [("member_guard", 90, "recorded")]
    assert lifts == [(90, "deactivation")]


def test_a_recorded_deactivation_takes_its_opener_time_reason_and_case_from_the_running_ban(lifts):
    banned_at = dt.datetime(2026, 10, 1, tzinfo=dt.UTC)
    conn = Conn(guard=None, latest=("ULYLA", banned_at, None, 5002, "indef_ban"))

    reactivation.reactivate(conn, "U1", "UMOD", "appeal accepted")

    assert conn.ran(reactivation.RECORD) == [("U1", "ULYLA", banned_at, "Indefinite ban", 5002)]


def test_active_account_without_bans_has_nothing_to_do(lifts):
    conn = Conn(guard=None, deactivated=False)

    assert reactivation.reactivate(conn, "U1", "UMOD", None) == ("nothing", [])
    assert conn.ran(reactivation.RECORD) == []
    assert lifts == []


def test_hand_held_deactivation_is_lifted_without_slack(lifts):
    conn = Conn(guard=(7, "by_hand", "live"))

    assert reactivation.reactivate(conn, "U1", "UMOD", None)[0] == "lifted"
    assert lifts == [(7, None)]


def test_firehose_deactivation_is_left_alone(lifts):
    conn = Conn(guard=(7, "firehose", "live"), bans=[(41, None)])

    assert reactivation.reactivate(conn, "U1", "UMOD", None) == ("firehose", [])
    assert lifts == [] and conn.ran(reactivation.END_BAN) == []


def test_a_guard_already_lifting_counts_as_queued(lifts):
    conn = Conn(guard=(7, "nemo", "lifting"))

    assert reactivation.reactivate(conn, "U1", "UMOD", None) == ("queued", [])
    assert lifts == []


def test_bans_can_be_left_running(lifts):
    conn = Conn(guard=(7, "nemo", "live"), bans=[(41, None)])

    assert reactivation.reactivate(conn, "U1", "UMOD", None, end_bans=False) == ("queued", [])
    assert conn.ran(reactivation.END_BAN) == []
