import pytest

from bot.core import whoami
from bot.nemo import channelguards
from bot.nemo.surface import bot_watch
from bot.nemo.views import activity

ROOM = "C1"
BOT_ID = "B1"
FACE = "U9"
TS = "1700000000.000200"
ROOT = "1700000000.000100"


class Conn:
    def __init__(self):
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        return (1,)


class _held:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *failure):
        return False


class Slack:
    def __init__(self, calls):
        self.calls = calls

    def __getattr__(self, method):
        def call(**kwargs):
            self.calls.append(method)
            return {"ok": True}
        return call


class Ctx:
    def __init__(self, event, client):
        self.payload = event
        self.client = client


class Wired:
    def __init__(self, calls, conn, tries, failures):
        self.calls, self.conn, self.tries, self.failures = calls, conn, tries, failures

    def __iter__(self):
        return iter((self.calls, self.conn))


@pytest.fixture
def wired(monkeypatch):
    calls = []
    conn = Conn()
    channelguards._held.clear()
    channelguards._held[(channelguards.BOT_ALLOWLIST, ROOM)] = channelguards.HeldGuard(
        7, {}, frozenset())
    channelguards._loaded = True
    bot_watch._apps[BOT_ID] = (FACE, "spammer", "A1")
    monkeypatch.setattr(whoami, "bot_user_id", lambda client, name: "UNEMO")
    def delete(channel_id, ts, max_retries=2):
        calls.append("chat.delete")
        tries.append(max_retries)
        if failures:
            raise failures.pop(0)

    tries, failures = [], []
    monkeypatch.setattr(bot_watch.privileged, "delete_message", delete)
    monkeypatch.setattr(bot_watch.privileged, "kick",
                        lambda channel_id, user_id: calls.append("conversations.kick") or "kicked")
    monkeypatch.setattr(bot_watch, "session", lambda: _held(conn))
    yield Wired(calls, conn, tries, failures)
    channelguards._held.clear()
    channelguards._loaded = False
    bot_watch._apps.clear()


def message(**over):
    return {"channel": ROOM, "ts": TS, "bot_id": BOT_ID, "subtype": "bot_message",
            "text": "buy now", **over}


def recorded(conn):
    (args,) = [args for sql, args in conn.ran if "INSERT INTO fd.channel_guard_events" in sql]
    return args


def test_the_delete_is_the_only_slack_call(wired):
    calls, _conn = wired

    assert bot_watch.posted(Ctx(message(), Slack(calls))) == 7
    assert calls == ["chat.delete"]


def test_the_link_is_built_without_asking_slack(wired):
    calls, conn = wired
    bot_watch.posted(Ctx(message(), Slack(calls)))

    assert f"{activity.ARCHIVES}/{ROOM}/p1700000000000200" in recorded(conn)


def test_the_delete_is_queued_for_a_notice(wired):
    calls, conn = wired
    bot_watch.posted(Ctx(message(), Slack(calls)))

    args = recorded(conn)
    assert args[2] == FACE
    assert args[5] == "deleted"
    assert args[-2:] == (True, False)


def test_a_bot_joining_is_kicked_and_queued_for_a_notice(wired):
    calls, conn = wired
    client = Slack(calls)
    client.users_info = lambda **kwargs: {"user": {
        "is_bot": True, "real_name": "spammer", "profile": {"bot_id": BOT_ID, "api_app_id": "A1"}}}

    assert bot_watch.joined(Ctx({"channel": ROOM, "user": FACE}, client)) == 7
    assert calls == ["conversations.kick"]
    args = recorded(conn)
    assert args[5] == "kicked"
    assert args[-3:] == (None, True, False)


def test_a_thread_reply_links_into_its_thread():
    assert activity.message_url(ROOM, TS, ROOT) == (
        f"{activity.ARCHIVES}/{ROOM}/p1700000000000200?thread_ts={ROOT}&cid={ROOM}"
    )


def test_a_top_level_message_links_without_a_thread():
    assert activity.message_url(ROOM, TS) == f"{activity.ARCHIVES}/{ROOM}/p1700000000000200"
    assert activity.message_url(ROOM, TS, TS) == f"{activity.ARCHIVES}/{ROOM}/p1700000000000200"


def throttled():
    failure = RuntimeError("proxy returned 429: budget: nemo:admin:chat.delete is spent")
    failure.http_status = 429
    return failure


def test_the_hot_path_never_sleeps_on_a_retry(wired):
    calls, _conn = wired
    bot_watch.posted(Ctx(message(), Slack(calls)))

    assert wired.tries == [0]


def test_a_delete_that_fails_is_queued_for_the_removal_worker(wired, caplog):
    calls, conn = wired
    wired.failures.append(throttled())
    caplog.set_level("INFO", logger="bot.nemo")

    assert bot_watch.posted(Ctx(message(), Slack(calls))) == 7
    args = recorded(conn)
    assert args[5] == "deleted"
    assert "429" in args[-3]
    assert args[-2:] == (True, True)
    assert any("queued for a retry" in one.getMessage() for one in caplog.records)


def test_a_message_that_is_already_gone_counts_as_deleted(wired):
    calls, conn = wired
    wired.failures.append(RuntimeError("message_not_found"))

    bot_watch.posted(Ctx(message(), Slack(calls)))

    args = recorded(conn)
    assert args[-3] is None
    assert args[-1] is False


def test_the_log_says_how_long_the_delete_took(wired, caplog):
    calls, _conn = wired
    caplog.set_level("INFO", logger="bot.nemo")
    bot_watch.posted(Ctx(message(), Slack(calls)))

    assert any("ms after it was posted" in one.getMessage() for one in caplog.records)
