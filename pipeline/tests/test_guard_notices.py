import pytest

from bot.nemo import channel, guard_notices

ROOM = "C1"
LOG = "CLOG"
BOT = "U9"
PARENT = "1700000000.000100"


def event(event_id, verb="deleted", subject=BOT, label="spammer", text="buy now", detail=None,
          message_ts="1700000000.000200"):
    return (event_id, ROOM, subject, verb, label, text, message_ts, f"https://link/{event_id}",
            "A1", detail)


def as_dict(row):
    return dict(zip(("id", "channel_id", "subject_id", "verb", "label", "message_text",
                     "message_ts", "permalink", "app_id", "detail"), row))


class Conn:
    def __init__(self, groups=(), claims=(), thread=None, totals=None, attempts=1):
        self.groups = list(groups)
        self.claims = [list(one) for one in claims]
        self.thread = thread
        self.totals = totals
        self.attempts = attempts
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        self.last = (sql, args)
        return self

    def fetchone(self):
        sql, args = self.last
        if "FROM fd.channel_guard_notice_threads" in sql:
            return self.thread
        if "INSERT INTO fd.channel_guard_notice_threads" in sql:
            return (11,)
        if "UPDATE fd.channel_guard_notice_threads" in sql:
            if self.totals is not None:
                return self.totals
            return (args[0], args[1])
        return (1,)

    def fetchall(self):
        sql, args = self.last
        if "GROUP BY guard_id, subject_id" in sql:
            return self.groups
        if "FOR UPDATE SKIP LOCKED" in sql:
            return self.claims.pop(0) if self.claims else []
        if "notice_attempts = notice_attempts + 1" in sql:
            return [(one, self.attempts) for one in args[0]]
        return []

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


class _held:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *failure):
        return False


class Slack:
    def __init__(self, fail_post_at=None, fail_update=False):
        self.fail_post_at = fail_post_at
        self.fail_update = fail_update
        self.posted = []
        self.updated = []

    def chat_postMessage(self, **kwargs):
        if self.fail_post_at is not None and len(self.posted) == self.fail_post_at:
            raise RuntimeError("slack is down")
        self.posted.append(kwargs)
        return {"ok": True, "ts": PARENT}

    def chat_update(self, **kwargs):
        if self.fail_update:
            raise RuntimeError("slack is down")
        self.updated.append(kwargs)
        return {"ok": True}


@pytest.fixture(autouse=True)
def log_channel(monkeypatch):
    monkeypatch.setattr(channel, "internal_log_channel", lambda conn=None: LOG)


def drained(monkeypatch, conn, client):
    monkeypatch.setattr(guard_notices, "session", lambda: _held(conn))
    return guard_notices.drain(client)


def test_a_burst_opens_one_parent_with_every_message_under_it(monkeypatch):
    burst = [event(n) for n in range(1, 11)]
    conn, client = Conn(groups=[(7, BOT)], claims=[burst]), Slack()

    drained(monkeypatch, conn, client)

    parent, *replies = client.posted
    assert "thread_ts" not in parent
    assert parent["channel"] == LOG
    assert "Deleted 10 messages." in parent["text"]
    assert len(replies) == 10
    assert {one["thread_ts"] for one in replies} == {PARENT}
    assert conn.did("INSERT INTO fd.channel_guard_notice_threads") == [(7, BOT, PARENT, 0, 0)]
    assert conn.did("UPDATE fd.channel_guard_notice_threads") == [(10, 0, 11)]
    assert conn.did("SET noticed_at = now()") == [(list(range(1, 11)),)]
    assert client.updated == []


def test_events_for_an_open_thread_reply_and_update_the_parent(monkeypatch):
    conn = Conn(groups=[(7, BOT)], claims=[[event(1), event(2)]],
                thread=(11, PARENT), totals=(5, 1))
    client = Slack()

    drained(monkeypatch, conn, client)

    assert len(client.posted) == 2
    assert {one["thread_ts"] for one in client.posted} == {PARENT}
    assert not conn.did("INSERT INTO fd.channel_guard_notice_threads")
    (update,) = client.updated
    assert update["ts"] == PARENT
    assert "Deleted 5 messages." in update["text"]
    assert "Removed from the channel 1 time." in update["text"]


def test_the_thread_lookup_uses_the_idle_timeout_and_max_age(monkeypatch):
    conn = Conn(groups=[(7, BOT)], claims=[[event(1)]])
    drained(monkeypatch, conn, Slack())

    (args,) = conn.did("FROM fd.channel_guard_notice_threads")
    assert args == (7, BOT, guard_notices.IDLE_TIMEOUT, guard_notices.MAX_AGE)


def test_the_claim_skips_notices_that_were_given_up(monkeypatch):
    conn = Conn(groups=[(7, BOT)], claims=[[event(1)]])
    drained(monkeypatch, conn, Slack())

    (args,) = conn.did("FOR UPDATE SKIP LOCKED")
    assert args == (7, BOT, guard_notices.GIVE_UP_AFTER, guard_notices.EVENTS_PER_CLAIM)
    (group_args,) = conn.did("GROUP BY guard_id, subject_id")
    assert group_args == (guard_notices.GIVE_UP_AFTER, guard_notices.GROUPS_PER_DRAIN)


def test_no_thread_is_opened_when_the_parent_cannot_be_posted(monkeypatch):
    conn = Conn(groups=[(7, BOT)], claims=[[event(1), event(2)]])

    drained(monkeypatch, conn, Slack(fail_post_at=0))

    assert not conn.did("INSERT INTO fd.channel_guard_notice_threads")
    assert not conn.did("SET noticed_at = now()")
    assert conn.did("notice_attempts = notice_attempts + 1") == [([1, 2],)]


def test_a_reply_that_fails_leaves_the_rest_for_the_next_drain(monkeypatch):
    conn = Conn(groups=[(7, BOT)], claims=[[event(1), event(2), event(3)]])
    client = Slack(fail_post_at=3)

    drained(monkeypatch, conn, client)

    assert conn.did("UPDATE fd.channel_guard_notice_threads") == [(2, 0, 11)]
    assert conn.did("SET noticed_at = now()") == [([1, 2],)]
    assert conn.did("notice_attempts = notice_attempts + 1") == [([3],)]
    (update,) = client.updated
    assert "Deleted 2 messages." in update["text"]


def test_a_notice_is_given_up_after_its_last_attempt(monkeypatch, caplog):
    conn = Conn(groups=[(7, BOT)], claims=[[event(1)]], attempts=guard_notices.GIVE_UP_AFTER)
    caplog.set_level("WARNING", logger="bot.nemo")

    drained(monkeypatch, conn, Slack(fail_post_at=0))

    assert any("gave up on the notice for guard event 1" in one.getMessage()
               for one in caplog.records)


def test_a_failed_update_still_marks_the_events_noticed(monkeypatch):
    conn = Conn(groups=[(7, BOT)], claims=[[event(1)]], thread=(11, PARENT), totals=(4, 0))

    drained(monkeypatch, conn, Slack(fail_update=True))

    assert conn.did("SET noticed_at = now()") == [([1],)]


def test_a_full_claim_is_followed_by_another(monkeypatch):
    monkeypatch.setattr(guard_notices, "EVENTS_PER_CLAIM", 2)
    conn = Conn(groups=[(7, BOT)], claims=[[event(1), event(2)], [event(3)]])
    client = Slack()

    drained(monkeypatch, conn, client)

    assert conn.did("SET noticed_at = now()") == [([1, 2],), ([3],)]


def test_one_failing_group_does_not_stop_the_others(monkeypatch):
    conn = Conn(groups=[(7, "U1"), (7, "U2")], claims=[[event(1, subject="U1")]])
    calls = []
    real = guard_notices.drain_group

    def flaky(client, guard_id, subject_id):
        calls.append(subject_id)
        if subject_id == "U1":
            raise RuntimeError("boom")
        return real(client, guard_id, subject_id)

    monkeypatch.setattr(guard_notices, "drain_group", flaky)
    drained(monkeypatch, conn, Slack())

    assert calls == ["U1", "U2"]


def test_drain_asks_for_another_pass_when_the_group_limit_is_hit(monkeypatch):
    monkeypatch.setattr(guard_notices, "GROUPS_PER_DRAIN", 1)
    conn = Conn(groups=[(7, BOT)], claims=[[event(1)]])

    assert drained(monkeypatch, conn, Slack()) is True


def test_details_read_like_the_old_notices():
    deleted = as_dict(event(1))
    kicked = {**deleted, "verb": "kicked", "message_ts": None}
    stuck = {**deleted, "verb": "let_past", "detail": "away", "message_ts": None}

    assert guard_notices.detail_of(deleted).startswith(
        f"Deleted a message from <@{BOT}>, which is not on the allow list for <#{ROOM}>.\n> buy now")
    assert "<https://link/1|message link>" in guard_notices.detail_of(deleted)
    assert guard_notices.detail_of(kicked).startswith(
        f"Put <@{BOT}> out of <#{ROOM}>, which is not on its allow list.")
    assert guard_notices.detail_of(stuck).startswith(
        f":warning: <@{BOT}> joined <#{ROOM}> off the allow list, and we could not put them "
        "out (away).")


def test_a_delete_that_was_given_up_says_so():
    kept = as_dict(event(1, verb="let_past", detail="cant_delete_message"))

    text = guard_notices.detail_of(kept)
    assert text.startswith(
        f":warning: Could not delete a message from <@{BOT}> in <#{ROOM}> (cant_delete_message).")
    assert "> buy now" in text
    assert "<https://link/1|message link>" in text


def test_notices_wait_for_a_queued_delete():
    from bot.nemo import channelguards

    assert "NOT remove_pending" in channelguards.CLAIM_NOTICES
    assert "NOT remove_pending" in channelguards.NOTICE_GROUPS


def test_a_bot_with_no_user_is_named_by_its_label():
    assert guard_notices.naming("B1", "spammer") == "*spammer*"
    assert guard_notices.naming("B1", None) == "*B1*"
    assert guard_notices.naming(BOT, "spammer") == f"<@{BOT}>"


def test_summary_pluralises():
    assert guard_notices.summary("*x*", ROOM, 1, 0) == (
        f"*x* is not on the allow list for <#{ROOM}>. Deleted 1 message."
    )
    assert guard_notices.summary("*x*", ROOM, 2, 2) == (
        f"*x* is not on the allow list for <#{ROOM}>. Deleted 2 messages. "
        "Removed from the channel 2 times."
    )
