import contextlib

import pytest

from bot.nemo import chat, handlers
from bot.nemo.surface import ENTRIES, reaction_watch


class App:
    def action(self, key):
        return lambda fn: fn

    def view(self, key):
        return lambda fn: fn


class Ctx:
    def __init__(self, payload):
        self.payload = payload
        self.client = None


class Conn:
    def __init__(self):
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        return None


def message_handler():
    return next(one for one in ENTRIES if one.tag == "handlers.on_message")


EVENT = {"channel": "C_FIRE", "ts": "2.0", "thread_ts": "1.0", "user": "UFD"}


@pytest.fixture
def harness(monkeypatch):
    recorded = {"replies": [], "stored": []}

    handlers.register(App(), lambda *args, **kw: recorded["replies"].append((args, kw)))

    @contextlib.contextmanager
    def fake_session():
        yield Conn()

    monkeypatch.setattr(handlers, "session", fake_session)
    monkeypatch.setattr(handlers, "case_channels", lambda conn=None: {"C_FIRE"})
    monkeypatch.setattr(handlers.chat, "case_of_thread", lambda conn, ts: 6)
    monkeypatch.setattr(handlers.access, "may", lambda conn, user_id, capability, case=None: (True, None))
    monkeypatch.setattr(
        handlers.chat, "store_message",
        lambda conn, case_id, event: (recorded["stored"].append((case_id, event)), (1, True))[1],
    )
    return recorded


def stub_is_reporter_thread(monkeypatch, answer):
    monkeypatch.setattr(handlers.chat, "is_reporter_thread", lambda conn, ts: answer)


def test_on_message_question_in_reporter_thread_sends_reply_to_member(harness, monkeypatch):
    stub_is_reporter_thread(monkeypatch, True)
    message_handler().fn(Ctx(dict(EVENT, text="?are you ok")))

    assert harness["replies"][0][0][1] == "are you ok"
    assert harness["stored"] == []


def test_on_message_question_without_reporter_thread_is_stored_as_chat(harness, monkeypatch):
    stub_is_reporter_thread(monkeypatch, False)
    message_handler().fn(Ctx(dict(EVENT, text="?are you ok")))

    assert harness["replies"] == []
    assert harness["stored"][0][0] == 6


def test_on_message_plain_chat_skips_reporter_thread_lookup(harness, monkeypatch):
    monkeypatch.setattr(handlers.chat, "is_reporter_thread", lambda conn, ts: 1 / 0)
    message_handler().fn(Ctx(dict(EVENT, text="who is handling this")))

    assert harness["stored"][0][0] == 6


def test_on_message_thread_broadcast_is_stored_as_chat(harness, monkeypatch):
    stub_is_reporter_thread(monkeypatch, False)
    message_handler().fn(Ctx(dict(EVENT, subtype="thread_broadcast", text="also posted to the channel")))

    assert harness["stored"] == [(6, dict(EVENT, subtype="thread_broadcast", text="also posted to the channel"))]


@pytest.mark.parametrize("subtype", ["channel_join", "bot_message"])
def test_on_message_non_chat_subtype_is_not_stored(harness, subtype):
    message_handler().fn(Ctx(dict(EVENT, subtype=subtype, text="joined")))

    assert harness["stored"] == []


def test_on_message_with_files_fetches_chat_files_with_the_client_token(harness, monkeypatch):
    stub_is_reporter_thread(monkeypatch, False)
    fetched = []
    monkeypatch.setattr(handlers.intake_files, "drain_chat_files", lambda token: fetched.append(token))

    class TokenClient:
        token = "xoxb-nemo"

    files = [{"id": "F1", "url_private": "https://files.slack.com/a.png"}]
    message_handler().fn(ClientCtx(dict(EVENT, subtype="file_share", text="", files=files), TokenClient()))
    for thread in [one for one in handlers.threading.enumerate() if one.name.startswith("nemo-chat-files-")]:
        thread.join(timeout=2)

    assert harness["stored"][0][1]["files"] == files
    assert fetched == ["xoxb-nemo"]


def test_attach_files_links_each_file_to_the_chat_line(monkeypatch):
    conn = Conn()
    monkeypatch.setattr(chat.intake, "store_file", lambda conn, item: {"F1": 501, "F2": 502}[item["slack_file_id"]])
    event = {"files": [{"id": "F1", "url_private": "https://files.slack.com/a.png"},
                       {"id": "F2", "url_private": "https://files.slack.com/b.png"}]}

    chat.attach_files(conn, 77, event)

    assert [args for sql, args in conn.executed if "fd.case_chat_files" in sql] == [(77, 501, 0), (77, 502, 1)]


ROOT_MESSAGE = {"ts": "1.0", "user": "UMEM", "text": "that's my alt"}


def test_store_root_message_stores_root_as_first_chat_message(monkeypatch):
    stored = []
    monkeypatch.setattr(
        reaction_watch.chat, "store_message",
        lambda conn, case_id, event: (stored.append((case_id, event)), (7, True))[1],
    )
    assert reaction_watch.store_root_message(None, 6, "C_FIRE", ROOT_MESSAGE) == 7
    assert stored[0][1]["channel"] == "C_FIRE"
    assert stored[0][1]["text"] == "that's my alt"


@pytest.mark.parametrize("message", [
    {},
    {"ts": "1.0", "user": "UMEM"},
    {"ts": "1.0", "text": "a bot said this"},
    {"user": "UMEM", "text": "no timestamp"},
])
def test_store_root_message_unstorable_root_returns_none(message, monkeypatch):
    monkeypatch.setattr(
        reaction_watch.chat, "store_message",
        lambda conn, case_id, event: 1 / 0,
    )
    assert reaction_watch.store_root_message(None, 6, "C_FIRE", message) is None


def test_is_storable_root_with_only_blocks_returns_true():
    assert reaction_watch.is_storable({"ts": "1.0", "user": "U1", "blocks": [{}]})


class SlackCalls:
    def __init__(self):
        self.calls = []

    def chat_postEphemeral(self, **kwargs):
        self.calls.append(kwargs)


class ClientCtx(Ctx):
    def __init__(self, payload, client):
        super().__init__(payload)
        self.client = client


DELETED = {"channel": "C_FIRE", "subtype": "message_deleted", "deleted_ts": "2.0",
           "previous_message": {"user": "UFD", "thread_ts": "1.0", "ts": "2.0", "text": "?thanks"}}


@pytest.mark.parametrize(("reply", "notifies_moderator"), [((10, 7, "signed", "2026-10-16", "thanks"), True), (None, False)])
def test_on_message_deleted_reply_notifies_moderator_only_when_delivered(harness, monkeypatch, reply, notifies_moderator):
    monkeypatch.setattr(handlers.chat, "delete", lambda conn, channel_id, ts: 5)
    monkeypatch.setattr(handlers.outbox, "reply_at", lambda conn, channel_id, ts: reply)
    client = SlackCalls()

    message_handler().fn(ClientCtx(dict(DELETED), client))

    expected = [{"channel": "C_FIRE", "user": "UFD", "thread_ts": "1.0", "text": handlers.views.edits.MODERATOR_DELETE}]
    assert client.calls == (expected if notifies_moderator else [])


def test_on_message_changed_reply_queues_edit_with_new_text(harness, monkeypatch):
    edited = []
    monkeypatch.setattr(handlers.chat, "edit", lambda conn, channel_id, message: 5)
    monkeypatch.setattr(handlers.outbox, "edit_reply",
                        lambda conn, channel_id, ts, body, by: edited.append((channel_id, ts, body, by)) or 55)
    changed = {"channel": "C_FIRE", "subtype": "message_changed",
               "message": {"ts": "2.0", "user": "UFD", "text": "?thanks, looking now", "edited": {"user": "UFD"}}}

    message_handler().fn(ClientCtx(changed, SlackCalls()))

    assert edited == [("C_FIRE", "2.0", "thanks, looking now", "UFD")]


def test_on_message_changed_non_reply_chat_queues_no_edit(harness, monkeypatch):
    edited = []
    monkeypatch.setattr(handlers.chat, "edit", lambda conn, channel_id, message: 5)
    monkeypatch.setattr(handlers.outbox, "edit_reply", lambda *args: edited.append(args))
    changed = {"channel": "C_FIRE", "subtype": "message_changed",
               "message": {"ts": "2.0", "user": "UFD", "text": "internal chat"}}

    message_handler().fn(ClientCtx(changed, SlackCalls()))

    assert edited == []
