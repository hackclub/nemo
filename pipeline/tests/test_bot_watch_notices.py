import pytest

from bot.nemo import channel
from bot.nemo.surface import bot_watch

ROOM = "C1"
LOG = "CLOG"
BOT = "U9"
PARENT = "1700000000.000100"


class Conn:
    def __init__(self, thread=None, totals=(2, 0)):
        self.thread = thread
        self.totals = totals
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        sql, _ = self.ran[-1]
        if "FROM fd.channel_guard_notice_threads" in sql:
            return self.thread
        if "INSERT INTO fd.channel_guard_notice_threads" in sql:
            return (11,)
        if "UPDATE fd.channel_guard_notice_threads" in sql:
            return self.totals
        return (1,)

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]

    def order(self):
        return [sql for sql, _ in self.ran]


class Slack:
    def __init__(self, fails=()):
        self.fails = fails
        self.posted = []
        self.updated = []

    def chat_postMessage(self, **kwargs):
        if "post" in self.fails:
            raise RuntimeError("slack is down")
        self.posted.append(kwargs)
        return {"ok": True, "ts": PARENT}

    def chat_update(self, **kwargs):
        if "update" in self.fails:
            raise RuntimeError("slack is down")
        self.updated.append(kwargs)
        return {"ok": True}


@pytest.fixture(autouse=True)
def log_channel(monkeypatch):
    monkeypatch.setattr(channel, "internal_log_channel", lambda conn=None: LOG)


def notice(client, conn, verb="deleted"):
    return bot_watch.post_notice(client, conn, 7, ROOM, BOT, f"<@{BOT}>", verb, "the detail")


def test_first_event_opens_a_parent_and_replies_under_it():
    client, conn = Slack(), Conn(thread=None)

    assert notice(client, conn) == PARENT
    parent, reply = client.posted
    assert "thread_ts" not in parent
    assert parent["channel"] == LOG
    assert "Deleted 1 message." in parent["text"]
    assert reply["thread_ts"] == PARENT
    assert reply["text"] == "the detail"
    assert conn.did("INSERT INTO fd.channel_guard_notice_threads") == [(7, BOT, PARENT, 1, 0)]
    assert client.updated == []


def test_event_in_an_open_thread_replies_and_updates_the_count():
    client, conn = Slack(), Conn(thread=(11, PARENT), totals=(3, 1))

    assert notice(client, conn) == PARENT
    (reply,) = client.posted
    assert reply["thread_ts"] == PARENT
    assert conn.did("UPDATE fd.channel_guard_notice_threads") == [(1, 0, 11)]
    assert not conn.did("INSERT INTO fd.channel_guard_notice_threads")
    (update,) = client.updated
    assert update["ts"] == PARENT
    assert "Deleted 3 messages." in update["text"]
    assert "Removed from the channel 1 time." in update["text"]


def test_lookup_uses_the_idle_timeout_and_max_age():
    conn = Conn(thread=None)
    notice(Slack(), conn)

    (args,) = conn.did("FROM fd.channel_guard_notice_threads")
    assert args == (7, BOT, bot_watch.NOTICE_IDLE_TIMEOUT, bot_watch.NOTICE_MAX_AGE)


def test_lock_is_taken_before_the_lookup():
    conn = Conn(thread=None)
    notice(Slack(), conn)

    ran = conn.order()
    lock = next(i for i, sql in enumerate(ran) if "pg_advisory_xact_lock" in sql)
    lookup = next(i for i, sql in enumerate(ran) if "FROM fd.channel_guard_notice_threads" in sql)
    assert lock < lookup
    assert conn.did("pg_advisory_xact_lock") == [(f"channel_guard_notice:7:{BOT}",)]


def test_kick_counts_as_a_removal():
    client, conn = Slack(), Conn(thread=None)
    notice(client, conn, verb="kicked")

    assert conn.did("INSERT INTO fd.channel_guard_notice_threads") == [(7, BOT, PARENT, 0, 1)]
    assert "Removed from the channel 1 time." in client.posted[0]["text"]


def test_failed_kick_replies_without_counting():
    client, conn = Slack(), Conn(thread=(11, PARENT), totals=(2, 0))
    notice(client, conn, verb="let_past")

    assert conn.did("UPDATE fd.channel_guard_notice_threads") == [(0, 0, 11)]


def test_no_thread_is_recorded_when_the_parent_cannot_be_posted():
    conn = Conn(thread=None)

    assert notice(Slack(fails=("post",)), conn) is None
    assert not conn.did("INSERT INTO fd.channel_guard_notice_threads")


def test_failed_update_still_returns_the_thread():
    conn = Conn(thread=(11, PARENT))

    assert notice(Slack(fails=("update",)), conn) == PARENT


def test_summary_pluralises():
    assert bot_watch.summary("*x*", ROOM, 1, 0) == (
        f"*x* is not on the allow list for <#{ROOM}>. Deleted 1 message."
    )
    assert bot_watch.summary("*x*", ROOM, 2, 2) == (
        f"*x* is not on the allow list for <#{ROOM}>. Deleted 2 messages. "
        "Removed from the channel 2 times."
    )
