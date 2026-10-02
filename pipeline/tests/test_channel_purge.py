import json

import pytest

from bot.nemo.carriers import purge

ROOM = "C1"


class Conn:
    def __init__(self, claims=True):
        self.claims = claims
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        sql, _ = self.ran[-1]
        if "SET state = 'running'" in sql:
            return (ROOM, 3) if self.claims else None
        return (1,)

    def fetchall(self):
        return []

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


class Slack:
    def __init__(self, pages=None, threads=None):
        self.pages = pages or []
        self.threads = threads or {}
        self.asked = []
        self.asked_replies = []

    def conversations_history(self, **kwargs):
        self.asked.append(kwargs)
        return self.pages.pop(0) if self.pages else {"messages": []}

    def conversations_replies(self, **kwargs):
        self.asked_replies.append(kwargs)
        held = self.threads.get(kwargs["ts"])
        if isinstance(held, list):
            return {"messages": held.pop(0) if held else []}
        return {"messages": held or []}


class _held:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *failure):
        return False


def message(ts, text="said a thing", **over):
    return {"ts": ts, "user": "U1", "text": text, **over}


def parent(ts, replies=1, **over):
    return message(ts, thread_ts=ts, reply_count=replies, **over)


@pytest.fixture
def wired(monkeypatch):
    conn = Conn()
    monkeypatch.setattr(purge, "session", lambda: _held(conn))
    taken = []
    monkeypatch.setattr(purge.guardwork, "remove",
                        lambda _c, room, ts: taken.append((room, ts)))
    return conn, taken


def test_a_purge_that_is_not_claimed_does_nothing(monkeypatch):
    conn = Conn(claims=False)
    monkeypatch.setattr(purge, "session", lambda: _held(conn))

    assert purge.run(Slack(), 7) == 0
    assert not conn.did("SET state = 'done'")


def test_the_newest_are_taken_down(wired):
    _conn, taken = wired
    client = Slack(pages=[{"messages": [message("3"), message("2"), message("1")]}])

    assert purge.run(client, 7) == 3
    assert taken == [(ROOM, "3"), (ROOM, "2"), (ROOM, "1")]


def test_what_was_taken_down_is_kept(wired):
    conn, _ = wired
    purge.run(Slack(pages=[{"messages": [message("3", "the thing said")]}]), 7)

    kept = json.loads(conn.did("SET state = 'done'")[0][1])
    assert kept[0]["ts"] == "3"
    assert kept[0]["text"] == "the thing said"
    assert kept[0]["user"] == "U1"


def test_it_stops_at_what_was_asked_for(wired):
    _, taken = wired
    client = Slack(pages=[{"messages": [message(str(n)) for n in range(9)]}])
    purge.run(client, 7)

    assert len(taken) == 3


def test_a_join_notice_is_not_counted(wired):
    _, taken = wired
    client = Slack(pages=[{"messages": [
        message("3", subtype="channel_join"), message("2"), message("1")]}])
    purge.run(client, 7)

    assert taken == [(ROOM, "2"), (ROOM, "1")]


def test_it_pages_until_it_has_enough(wired):
    _, taken = wired
    client = Slack(pages=[
        {"messages": [message("5")], "response_metadata": {"next_cursor": "more"}},
        {"messages": [message("4")], "response_metadata": {"next_cursor": "more"}},
        {"messages": [message("3")]},
    ])
    purge.run(client, 7)

    assert len(taken) == 3
    assert client.asked[1]["cursor"] == "more"


def test_running_out_of_messages_ends_it(wired):
    conn, taken = wired
    purge.run(Slack(pages=[{"messages": [message("1")]}]), 7)

    assert len(taken) == 1
    assert conn.did("SET state = 'done'")


def test_a_failure_keeps_what_it_managed(monkeypatch):
    conn = Conn()
    monkeypatch.setattr(purge, "session", lambda: _held(conn))
    taken = []

    def remove(_c, room, ts):
        if ts == "2":
            raise RuntimeError("slack said no")
        taken.append((room, ts))

    monkeypatch.setattr(purge.guardwork, "remove", remove)
    purge.run(Slack(pages=[{"messages": [message("3"), message("2"), message("1")]}]), 7)

    failed = conn.did("state = 'failed'")[0]
    assert failed[0] == 1
    assert "slack said no" in failed[2]
    assert json.loads(failed[1])[0]["ts"] == "3"


def test_it_never_takes_more_than_the_cap(wired):
    _conn, taken = wired
    client = Slack(pages=[{"messages": [message(str(n)) for n in range(300)]}])
    purge.run(client, 7)

    assert len(taken) <= purge.MOST


def test_a_thread_goes_down_with_its_parent(wired):
    _conn, taken = wired
    client = Slack(
        pages=[{"messages": [parent("3", replies=2)]}],
        threads={"3": [[message("3.1"), message("3.2")], []]},
    )
    purge.run(client, 7)

    assert taken == [(ROOM, "3.1"), (ROOM, "3.2"), (ROOM, "3")]


def test_the_replies_go_before_the_parent(wired):
    _conn, taken = wired
    client = Slack(
        pages=[{"messages": [parent("3")]}],
        threads={"3": [[message("3.1")], []]},
    )
    purge.run(client, 7)

    assert taken[-1] == (ROOM, "3")


def test_a_reply_is_kept_against_its_thread(wired):
    conn, _ = wired
    client = Slack(
        pages=[{"messages": [parent("3")]}],
        threads={"3": [[message("3.1", "in the thread")], []]},
    )
    purge.run(client, 7)

    kept = json.loads(conn.did("SET state = 'done'")[0][1])
    assert kept[0]["ts"] == "3.1"
    assert kept[0]["thread_ts"] == "3"
    assert kept[1]["ts"] == "3"
    assert kept[1]["thread_ts"] is None


def test_a_plain_message_is_not_asked_about(wired):
    _conn, _taken = wired
    client = Slack(pages=[{"messages": [message("3")]}])
    purge.run(client, 7)

    assert client.asked_replies == []


def test_replies_posted_mid_purge_are_caught(wired):
    _conn, taken = wired
    client = Slack(
        pages=[{"messages": [parent("3")]}],
        threads={"3": [[message("3.1")], [message("3.2")], []]},
    )
    purge.run(client, 7)

    assert taken == [(ROOM, "3.1"), (ROOM, "3.2"), (ROOM, "3")]


def test_a_thread_beyond_the_ceiling_stops_and_says_so(wired):
    conn, taken = wired
    huge = [message(f"3.{n}") for n in range(purge.CEILING + 10)]
    client = Slack(pages=[{"messages": [parent("3")]}], threads={"3": [huge, []]})
    purge.run(client, 7)

    failed = conn.did("state = 'failed'")[0]
    assert len(taken) == purge.CEILING
    assert "hang off" in failed[2]


def test_the_count_covers_the_replies_too(wired):
    conn, _ = wired
    client = Slack(
        pages=[{"messages": [parent("3", replies=2), message("2")]}],
        threads={"3": [[message("3.1"), message("3.2")], []]},
    )

    assert purge.run(client, 7) == 4
    assert conn.did("SET state = 'done'")[0][0] == 4
