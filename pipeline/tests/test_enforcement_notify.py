import datetime as dt

from bot.nemo.enforcement import notify

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
        args = self.ran[-1][1]
        if "verb = %s AND at >" in self.ran[-1][0]:
            return (self.counts.get(args[1], 0),)
        return (1,)

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


class Slack:
    def __init__(self, fails=()):
        self.posted = []
        self.ephemeral = []
        self.fails = fails

    def chat_postMessage(self, **kwargs):
        if "dm" in self.fails:
            raise RuntimeError("cannot dm them")
        self.posted.append(kwargs)
        return {"ts": "9.9"}

    def chat_postEphemeral(self, **kwargs):
        if "post_ephemeral" in self.fails:
            raise RuntimeError("not in channel")
        self.ephemeral.append(kwargs)
        return {"ok": True}


def guard(**over):
    row = {"id": 7, "kind": "shush", "subject_id": WHO, "channel_id": None,
           "reason": "being awful", "expires_at": ENDS}
    row.update(over)
    return row


def event(**over):
    row = {"channel": ROOM, "user": WHO, "ts": TS, "subtype": None}
    row.update(over)
    return row


def test_a_date_reads_as_a_date_and_none_says_so():
    assert notify.ending(guard()) == "until 10 Mar"
    assert notify.ending(guard(expires_at=None)) == "with no end date"


def test_a_message_with_words_in_it_is_ours():
    assert notify.ours(event()) == (ROOM, WHO, TS)


def test_a_direct_message_is_never_ours():
    assert notify.ours(event(channel="D1"))[0] is None


def test_a_bot_message_is_never_ours():
    assert notify.ours(event(bot_id="B1"))[0] is None


def test_a_subtype_that_carries_nothing_is_skipped():
    for subtype in ("channel_join", "message_deleted", "message_changed"):
        assert notify.ours(event(subtype=subtype))[0] is None, subtype


def test_every_subtype_that_carries_words_is_ours():
    for subtype in (None, "file_share", "thread_broadcast", "me_message"):
        assert notify.ours(event(subtype=subtype))[0] == ROOM, subtype


def test_the_notification_is_written_down():
    conn, client = Conn(), Slack()
    notify.dm_subject(client, conn, guard(), "you've been shushed")
    assert client.posted[0]["channel"] == WHO
    assert conn.did("INSERT INTO fd.member_guard_events")[0][3] == "notified"


def test_a_dm_that_will_not_send_is_written_down_as_such():
    conn = Conn()
    notify.dm_subject(Slack(fails=("dm",)), conn, guard(), "anything")
    assert conn.did("INSERT INTO fd.member_guard_events")[0][6].startswith("could not notify")


def test_a_whisper_that_will_not_send_is_swallowed():
    notify.post_ephemeral(Slack(fails=("post_ephemeral",)), ROOM, WHO, "anything")


def test_ten_in_an_hour_earns_a_reset():
    assert notify.reset_threshold_met(Conn({"deleted": 10, "reset": 0}), guard(), "deleted")


def test_nine_in_an_hour_does_not():
    assert not notify.reset_threshold_met(Conn({"deleted": 9, "reset": 0}), guard(), "deleted")


def test_one_reset_an_hour_is_enough():
    assert not notify.reset_threshold_met(Conn({"deleted": 40, "reset": 1}), guard(), "deleted")


def test_each_carrier_counts_its_own_verb():
    held = Conn({"deleted": 10, "kicked": 0, "reset": 0})
    assert notify.reset_threshold_met(held, guard(), "deleted")
    assert not notify.reset_threshold_met(held, guard(), "kicked")


def test_the_count_only_looks_back_an_hour():
    conn = Conn({"deleted": 10, "reset": 0})
    notify.reset_threshold_met(conn, guard(), "deleted")
    assert all(args[2] == "1 hour" for args in conn.did("verb = %s AND at >"))


def test_a_reset_is_written_down_with_what_came_of_it(monkeypatch):
    monkeypatch.setattr(notify.privileged, "reset_sessions", lambda who: "reset")
    conn = Conn()
    assert notify.reset(conn, guard(), "posting") == "reset"
    recorded = conn.did("INSERT INTO fd.member_guard_events")[0]
    assert recorded[3] == "reset"
    assert recorded[6] == "reset"
