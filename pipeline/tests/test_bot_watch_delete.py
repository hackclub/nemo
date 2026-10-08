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
    notices = []
    channelguards._held.clear()
    channelguards._held[(channelguards.BOT_ALLOWLIST, ROOM)] = channelguards.HeldGuard(
        7, {}, frozenset())
    channelguards._loaded = True
    bot_watch._apps[BOT_ID] = (FACE, "spammer", "A1")
    monkeypatch.setattr(whoami, "bot_user_id", lambda client, name: "UNEMO")
    monkeypatch.setattr(bot_watch.privileged, "delete_message",
                        lambda channel_id, ts: calls.append("chat.delete"))
    monkeypatch.setattr(bot_watch, "session", lambda: _held(conn))
    monkeypatch.setattr(bot_watch, "post_notice",
                        lambda *args: notices.append(args[-1]))
    yield calls, conn, notices
    channelguards._held.clear()
    channelguards._loaded = False
    bot_watch._apps.clear()


def message(**over):
    return {"channel": ROOM, "ts": TS, "bot_id": BOT_ID, "subtype": "bot_message",
            "text": "buy now", **over}


def test_the_delete_is_the_first_slack_call(wired):
    calls, _conn, _notices = wired

    assert bot_watch.posted(Ctx(message(), Slack(calls))) == 7
    assert calls[0] == "chat.delete"
    assert "chat_getPermalink" not in calls


def test_the_link_is_built_without_asking_slack(wired):
    calls, conn, notices = wired
    bot_watch.posted(Ctx(message(), Slack(calls)))

    link = f"{activity.ARCHIVES}/{ROOM}/p1700000000000200"
    (recorded,) = [args for sql, args in conn.ran if "INSERT INTO fd.channel_guard_events" in sql]
    assert link in recorded
    assert link in notices[0]


def test_a_thread_reply_links_into_its_thread():
    assert activity.message_url(ROOM, TS, ROOT) == (
        f"{activity.ARCHIVES}/{ROOM}/p1700000000000200?thread_ts={ROOT}&cid={ROOM}"
    )


def test_a_top_level_message_links_without_a_thread():
    assert activity.message_url(ROOM, TS) == f"{activity.ARCHIVES}/{ROOM}/p1700000000000200"
    assert activity.message_url(ROOM, TS, TS) == f"{activity.ARCHIVES}/{ROOM}/p1700000000000200"


def test_the_log_says_how_long_the_delete_took(wired, caplog):
    calls, _conn, _notices = wired
    caplog.set_level("INFO", logger="bot.nemo")
    bot_watch.posted(Ctx(message(), Slack(calls)))

    assert any("ms after it was posted" in one.getMessage() for one in caplog.records)
