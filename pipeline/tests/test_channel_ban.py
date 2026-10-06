import datetime as dt

import pytest

from bot.nemo import memberguards
from bot.nemo.enforcement import channel_ban


class _held:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *failure):
        return False


class Ctx:
    def __init__(self, event, client=None):
        self.payload = event
        self.client = client or Slack()


def event(**over):
    return {"user": WHO, "channel": ROOM, "ts": TS, "text": "hey", **over}

WHO = "U1"
ROOM = "C1"
TS = "1700000000.000100"
ENDS = dt.datetime(2026, 3, 10, 12, tzinfo=dt.UTC)


class Conn:
    def __init__(self, counts=None):
        self.counts = counts or {}
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        sql, args = self.ran[-1]
        if "verb = %s AND at >" in sql:
            return (self.counts.get(args[1], 0),)
        return (1,)

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]

    def executed(self, mark):
        return any(mark in sql for sql, _ in self.ran)

    def verbs(self):
        return [args[3] for args in self.did("INSERT INTO fd.member_guard_events")]


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
    row = {"id": 7, "kind": "channel_ban", "subject_id": WHO, "channel_id": ROOM,
           "reason": "being awful", "expires_at": ENDS}
    row.update(over)
    return row


@pytest.fixture
def kicks(monkeypatch):
    done = []

    def kick(room, who):
        done.append((room, who))
        return "kicked"

    monkeypatch.setattr(channel_ban.privileged, "kick", kick)
    return done


@pytest.fixture
def cannot_kick(monkeypatch):
    monkeypatch.setattr(channel_ban.privileged, "kick",
                        lambda room, who: "failed: cant_kick_from_general")


def test_taking_one_up_puts_them_out_and_tells_them_where_from(kicks):
    conn, client = Conn(), Slack()
    assert channel_ban.take_up(client, conn, guard())

    assert kicks == [(ROOM, WHO)]
    assert conn.executed("enforcement_status = 'held'")
    assert "kicked" in conn.verbs()

    text = client.posted[0]["text"]
    assert f"banned from <#{ROOM}>" in text
    assert "for being awful" in text
    assert "until 10 Mar" in text


def test_one_it_cannot_put_out_is_not_claimed_as_held(cannot_kick):
    conn, client = Conn(), Slack()
    assert not channel_ban.take_up(client, conn, guard())

    assert conn.executed("enforcement_status = 'failed'")
    assert not conn.executed("enforcement_status = 'held'")
    assert conn.verbs() == ["failed"]
    assert client.posted == [], "nothing is claimed to them that did not happen"


def test_a_channel_nobody_can_be_kicked_from_keeps_the_reason(cannot_kick):
    conn = Conn()
    channel_ban.take_up(Slack(), conn, guard())
    assert "cant_kick_from_general" in conn.did("SET enforcement_status = 'failed'")[0][0]


def test_seen_tells_them_inside_the_thread_they_posted_in(kicks, monkeypatch):
    monkeypatch.setattr(channel_ban, "session", lambda: _held(Conn()))
    monkeypatch.setattr(channel_ban.guard_actions, "remove", lambda client, room, ts: True)
    memberguards._bans[(WHO, ROOM)] = guard()
    memberguards._loaded = True
    try:
        client = Slack()
        channel_ban.seen(Ctx(event(thread_ts="1700000000.000000"), client))
        assert client.ephemeral[0]["thread_ts"] == "1700000000.000000"
    finally:
        memberguards._bans.clear()
        memberguards._loaded = False


def test_seen_tells_them_channel_wide_outside_a_thread(kicks, monkeypatch):
    monkeypatch.setattr(channel_ban, "session", lambda: _held(Conn()))
    monkeypatch.setattr(channel_ban.guard_actions, "remove", lambda client, room, ts: True)
    memberguards._bans[(WHO, ROOM)] = guard()
    memberguards._loaded = True
    try:
        client = Slack()
        channel_ban.seen(Ctx(event(), client))
        assert client.ephemeral[0]["thread_ts"] is None
    finally:
        memberguards._bans.clear()
        memberguards._loaded = False


def test_coming_back_gets_them_put_out_again(kicks):
    conn = Conn()
    assert channel_ban.remove_from_channel(conn, guard())
    assert kicks == [(ROOM, WHO)]
    assert conn.verbs() == ["kicked"]


def test_ten_returns_in_an_hour_earns_a_reset(kicks, monkeypatch):
    monkeypatch.setattr(channel_ban.notify.privileged, "reset_sessions", lambda who: "reset")
    conn = Conn({"kicked": 10, "reset": 0})
    assert channel_ban.reapply(conn, guard(), "coming back")
    assert "reset" in conn.verbs()


def test_nine_returns_does_not(kicks):
    conn = Conn({"kicked": 9, "reset": 0})
    assert not channel_ban.reapply(conn, guard(), "coming back")
    assert "reset" not in conn.verbs()


def test_a_ban_counts_its_own_kicks_not_somebody_elses_deletes(kicks):
    conn = Conn({"kicked": 0, "deleted": 40, "reset": 0})
    assert not channel_ban.reapply(conn, guard(), "coming back")


def test_lifting_does_not_invite_them_back():
    src = (channel_ban.__doc__ or "") + open(channel_ban.__file__).read()
    assert "conversations_invite" not in src
    assert "invite" not in src.replace("invite_the_admin", "")


def test_a_ban_is_only_found_in_the_channel_it_was_made_in():
    memberguards._loaded = True
    memberguards._bans.clear()
    memberguards._bans[(WHO, ROOM)] = guard()

    assert memberguards.banned(WHO, ROOM) is not None
    assert memberguards.banned(WHO, "CELSEWHERE") is None
    assert memberguards.banned("USOMEBODY", ROOM) is None
    memberguards._loaded = False
    memberguards._bans.clear()
