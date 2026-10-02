import pathlib

import pytest

from bot.nemo import memberguards
from bot.nemo.carriers import deactivate

WHO = "U1"


class Conn:
    def __init__(self, lifts=True, finds=True):
        self.lifts = lifts
        self.finds = finds
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        sql, _ = self.ran[-1]
        if "JOIN fd.actions" in sql:
            return (7, memberguards.DEACTIVATION) if self.finds else None
        if "SET state = 'lifted'" in sql:
            return (7,) if self.lifts else None
        return (7,)

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]

    def said(self, mark):
        return any(mark in sql for sql, _ in self.ran)


class Slack:
    pass


def guard(**over):
    row = {"id": 7, "kind": "deactivation", "subject_id": WHO, "channel_id": None,
           "reason": "raiding", "expires_at": None}
    row.update(over)
    return row


@pytest.fixture
def took(monkeypatch):
    def answer(how):
        monkeypatch.setattr(deactivate.privileged, "deactivate", lambda who: how)
        monkeypatch.setattr(deactivate.privileged, "reactivate", lambda who: how)
    return answer


def test_taking_one_up_holds_the_guard_and_writes_down_what_slack_did(took):
    took("deactivated")
    conn = Conn()
    assert deactivate.take_up(Slack(), conn, guard())

    assert conn.said("carry = 'held'")
    said = conn.did("INSERT INTO fd.member_guard_events")[0]
    assert said[3] == "deactivated"
    assert said[6] == "deactivated"


def test_an_account_slack_would_not_take_down_drops_the_guard(took):
    took("failed: user_not_found")
    conn = Conn()
    assert not deactivate.take_up(Slack(), conn, guard())

    assert conn.said("carry = 'failed'")
    assert not conn.said("carry = 'held'")
    assert conn.did("INSERT INTO fd.member_guard_events")[0][3] == "failed"


@pytest.mark.parametrize("how", ["off", "would"])
def test_a_run_that_is_not_armed_still_reads_as_carried(took, how):
    took(how)
    conn = Conn()
    assert deactivate.take_up(Slack(), conn, guard())
    assert conn.said("carry = 'held'")


def test_lifting_puts_them_back_before_the_guard_reads_as_lifted(took):
    took("reactivated")
    conn = Conn()
    assert deactivate.let_go(Slack(), conn, guard())

    assert conn.said("state = 'lifted'")
    assert conn.did("INSERT INTO fd.member_guard_events")[0][3] == "reactivated"


def test_a_lift_slack_refuses_leaves_the_guard_lifting(took):
    took("failed: rate limited")
    conn = Conn()
    assert not deactivate.let_go(Slack(), conn, guard())

    assert not conn.said("state = 'lifted'")
    assert conn.did("INSERT INTO fd.member_guard_events")[0][3] == "failed"


def test_a_lift_that_was_already_finished_says_so_once(took):
    took("reactivated")
    conn = Conn(lifts=False)
    assert deactivate.let_go(Slack(), conn, guard())
    assert conn.did("INSERT INTO fd.member_guard_events") == []


def test_reversing_the_last_live_action_lifts_what_it_held():
    conn = Conn()
    assert memberguards.lift_for_action(conn, 3, "UME", "the action was reversed: appeal") == 7

    asked, args = conn.ran[0]
    assert "o.reversed_at IS NULL" in asked, "a guard another live action wants must stay"
    assert args == (3,)
    assert conn.said("state = 'lifting'"), "a deactivation waits for slack before it is lifted"


def test_reversing_an_action_that_held_nothing_lifts_nothing():
    conn = Conn(finds=False)
    assert memberguards.lift_for_action(conn, 3, "UME", "why") is None
    assert not conn.said("UPDATE fd.member_guards")


def test_only_a_deactivation_waits_for_slack_before_it_reads_as_lifted():
    assert memberguards.undone_in_slack(memberguards.DEACTIVATION)
    assert not memberguards.undone_in_slack(memberguards.SHUSH)
    assert not memberguards.undone_in_slack(memberguards.CHANNEL_BAN)


def test_the_lift_the_web_asks_for_reaches_the_bot_without_waiting_for_a_sweep():
    from bot.nemo import loop

    watched = pathlib.Path(loop.__file__).read_text()
    assert "still_lifting" in watched, "the listener must drain what is lifting"
    assert "target=carry_now" in watched


def test_the_kind_and_the_events_the_database_will_take():
    said = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0140_deactivation_guards.sql").read_text()
    assert "'shush', 'channel_ban', 'deactivation'" in said
    assert "'deactivated', 'reactivated'" in said
