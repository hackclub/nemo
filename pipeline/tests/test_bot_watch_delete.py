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
    monkeypatch.setattr(bot_watch.privileged, "delete_message",
                        lambda channel_id, ts: calls.append("chat.delete"))
    monkeypatch.setattr(bot_watch.privileged, "kick",
                        lambda channel_id, user_id: calls.append("conversations.kick") or "kicked")
    monkeypatch.setattr(bot_watch, "session", lambda: _held(conn))
    yield calls, conn
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
    assert args[-1] is True


def test_a_bot_joining_is_kicked_and_queued_for_a_notice(wired):
    calls, conn = wired
    client = Slack(calls)
    client.users_info = lambda **kwargs: {"user": {
        "is_bot": True, "real_name": "spammer", "profile": {"bot_id": BOT_ID, "api_app_id": "A1"}}}

    assert bot_watch.joined(Ctx({"channel": ROOM, "user": FACE}, client)) == 7
    assert calls == ["conversations.kick"]
    args = recorded(conn)
    assert args[5] == "kicked"
    assert args[-2:] == (None, True)


def test_a_thread_reply_links_into_its_thread():
    assert activity.message_url(ROOM, TS, ROOT) == (
        f"{activity.ARCHIVES}/{ROOM}/p1700000000000200?thread_ts={ROOT}&cid={ROOM}"
    )


def test_a_top_level_message_links_without_a_thread():
    assert activity.message_url(ROOM, TS) == f"{activity.ARCHIVES}/{ROOM}/p1700000000000200"
    assert activity.message_url(ROOM, TS, TS) == f"{activity.ARCHIVES}/{ROOM}/p1700000000000200"


def test_the_log_says_how_long_the_delete_took(wired, caplog):
    calls, _conn = wired
    caplog.set_level("INFO", logger="bot.nemo")
    bot_watch.posted(Ctx(message(), Slack(calls)))

    assert any("ms after it was posted" in one.getMessage() for one in caplog.records)
