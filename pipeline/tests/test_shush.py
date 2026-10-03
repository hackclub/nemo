import datetime as dt
import pathlib

import pytest

from bot.nemo import memberguards
from bot.nemo.enforcement import shush

WHO = "U1"
ROOM = "C1"
TS = "1700000000.000100"
ENDS = dt.datetime(2026, 3, 10, 12, tzinfo=dt.UTC)


class Conn:
    def __init__(self, counts=None, claims=True):
        self.counts = counts or {}
        self.claims = claims
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        sql, args = self.ran[-1]
        if "verb = %s AND at >" in sql:
            return (self.counts.get(args[1], 0),)
        if "carry = 'held'" in sql:
            return (7,) if self.claims else None
        return (1,)

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]

    def executed(self, mark):
        return any(mark in sql for sql, _ in self.ran)


class Slack:
    def __init__(self):
        self.posted = []
        self.ephemeral = []

    def chat_postMessage(self, **kwargs):
        self.posted.append(kwargs)
        return {"ts": "9.9"}

    def chat_postEphemeral(self, **kwargs):
        self.ephemeral.append(kwargs)
        return {"ok": True}


def guard(**over):
    row = {"id": 7, "kind": "shush", "subject_id": WHO, "channel_id": None,
           "reason": "being awful", "expires_at": ENDS}
    row.update(over)
    return row


@pytest.fixture(autouse=True)
def quiet(monkeypatch):
    monkeypatch.setattr(shush.guard_actions, "remove", lambda client, room, ts: True)


def test_taking_one_up_tells_them_once_and_says_when_it_ends():
    conn, client = Conn(), Slack()
    assert shush.take_up(client, conn, guard())

    posted = client.posted[0]
    assert posted["channel"] == WHO
    assert "you've been shushed for being awful" in posted["text"]
    assert "until 10 Mar" in posted["text"]
    assert conn.did("INSERT INTO fd.member_guard_events")[0][3] == "told"


def test_one_that_never_ends_says_so_rather_than_a_date():
    client = Slack()
    shush.take_up(client, Conn(), guard(expires_at=None))
    assert "with no end date" in client.posted[0]["text"]


def test_one_already_held_is_not_told_again():
    client = Slack()
    assert not shush.take_up(client, Conn(claims=False), guard())
    assert client.posted == []


def test_a_removed_message_is_written_down_and_the_guard_reads_as_held():
    conn = Conn()
    assert shush.remove(Slack(), conn, guard(), ROOM, TS)

    assert conn.executed("carry = 'held'")
    told = conn.did("INSERT INTO fd.member_guard_events")[0]
    assert told[3] == "deleted"
    assert told[4] == TS


def test_a_message_that_will_not_go_drops_the_guard(monkeypatch):
    def cannot(client, room, ts):
        raise RuntimeError("channel_not_found")

    monkeypatch.setattr(shush.guard_actions, "remove", cannot)
    conn = Conn()
    assert not shush.remove(Slack(), conn, guard(), ROOM, TS)

    assert conn.executed("carry = 'failed'")
    assert conn.did("INSERT INTO fd.member_guard_events")[0][3] == "failed"


def test_the_live_set_is_only_what_is_still_live():
    assert "state = 'live'" in memberguards.LIVE_GUARDS
    assert "lifting" not in memberguards.LIVE_GUARDS


def test_only_what_nemo_carries_is_taken_up():
    assert "carried_by = 'nemo'" in memberguards.UNCARRIED
    assert "carry = 'pending'" in memberguards.UNCARRIED


def test_nothing_is_shushed_until_the_set_has_been_loaded():
    memberguards._loaded = False
    assert memberguards.shushed(WHO) is None
    assert memberguards.banned(WHO, ROOM) is None


def test_a_guard_the_web_opens_reaches_the_bot_without_waiting_for_a_sweep():
    from bot.nemo import loop

    assert loop.MEMBER_GUARD == "fd_member_guard"
    watched = pathlib.Path(loop.__file__).read_text()
    assert "MEMBER_GUARD, APP_SETTING" in watched, "the loop must LISTEN for it"
    assert "elif channel_name == MEMBER_GUARD:" in watched


def test_the_trigger_that_wakes_the_bot_fires_on_a_fresh_guard():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0131_member_guards.sql").read_text()
    assert "AFTER INSERT OR UPDATE OF state, carry, expires_at, case_id OR DELETE" in sql
    assert "pg_notify('fd_member_guard'" in sql
