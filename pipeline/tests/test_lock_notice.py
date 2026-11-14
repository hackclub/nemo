import contextlib
import datetime as dt

import pytest

from bot.core import privileged
from bot.core.formatting import short_end
from bot.nemo import guard_actions, guards, userbots
from bot.nemo.surface import thread_watch
from bot.nemo.views import guard as card

CHANNEL_ID = "C1"
THREAD = "1700000000.000000"
TS = "1700000000.000100"
MOD = "UMOD"
USER_ID = "U1"
END = dt.datetime(2026, 10, 17, 14, 30, tzinfo=dt.UTC)


@contextlib.contextmanager
def session_of(conn=None):
    yield conn


def test_lock_notice_with_end_returns_end_and_reason():
    notice = card.lock_notice(END, "Heated argument")

    assert notice["text"] == f"*Thread locked* until {short_end(END)} for *Heated argument*"
    assert len(notice["blocks"]) == 1


def test_lock_notice_has_unlock_menu_with_confirm():
    menu = card.lock_notice(END, "Heated argument")["blocks"][0]["accessory"]

    assert menu["type"] == "overflow"
    assert menu["action_id"] == card.NOTICE_MENU
    assert [(one["text"]["text"], one["value"]) for one in menu["options"]] == [
        ("Unlock thread", card.NOTICE_UNLOCK)]
    assert menu["confirm"]["confirm"]["text"] == "Unlock"


def test_lock_notice_signs_out_true_appends_sign_out_warning():
    notice = card.lock_notice(None, "raid", signs_out=True)

    assert notice["text"] == "*Thread locked* with no end date for *raid*"
    assert notice["blocks"][1]["elements"][0]["text"] == card.SIGNS_OUT


@pytest.mark.parametrize(("mode", "warns"), [(privileged.ON, True), (privileged.LOG, False), (privileged.OFF, False)])
def test_guard_actions_lock_notice_sign_out_warning_follows_privileged_mode(monkeypatch, mode, warns):
    monkeypatch.setattr(privileged, "mode", lambda conn=None: mode)

    notice = guard_actions.lock_notice(object(), END, "raid")

    assert (len(notice["blocks"]) > 1) is warns


def test_lock_removal_notice_quotes_deleted_reply():
    notice = card.lock_removal_notice(END, "but nobody answered")

    assert notice["text"] == f"*Thread locked* until {short_end(END)}"
    assert notice["blocks"][1]["elements"][0]["elements"][0]["text"] == "but nobody answered"


class Slack:
    def __init__(self, react_error=None):
        self.react_error = react_error
        self.posted = []
        self.reactions_added = []
        self.reactions_removed = []
        self.updated = []
        self.deleted = []
        self.ephemeral = []

    def chat_postMessage(self, **kwargs):
        self.posted.append(kwargs)
        return {"ts": "1700000000.000500"}

    def reactions_add(self, **kwargs):
        if self.react_error:
            raise RuntimeError(self.react_error)
        self.reactions_added.append(kwargs)

    def reactions_remove(self, **kwargs):
        self.reactions_removed.append(kwargs)

    def chat_update(self, **kwargs):
        self.updated.append(kwargs)

    def chat_delete(self, **kwargs):
        self.deleted.append(kwargs)

    def chat_postEphemeral(self, **kwargs):
        self.ephemeral.append(kwargs)


class Conn:
    def __init__(self, queued_rows=()):
        self.queued_rows = list(queued_rows)
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchall(self):
        return self.queued_rows


def test_warn_lock_posts_notice_and_adds_lock_reaction():
    client = Slack()
    notice = card.lock_notice(END, "raid")

    assert guards.warn(client, Conn(), 5, CHANNEL_ID, THREAD, guards.LOCK, notice=notice) == "1700000000.000500"
    assert client.posted[0]["blocks"] == notice["blocks"]
    assert client.reactions_added == [{"channel": CHANNEL_ID, "timestamp": THREAD, "name": "lock"}]


def test_warn_lock_reaction_error_still_returns_notice_ts():
    client = Slack(react_error="already_reacted")

    assert guards.warn(client, Conn(), 5, CHANNEL_ID, THREAD, guards.LOCK) == "1700000000.000500"


def test_warn_destroy_does_not_add_reaction():
    client = Slack()

    guards.warn(client, Conn(), 5, CHANNEL_ID, THREAD, guards.DESTROY)

    assert client.reactions_added == []
    assert client.posted[0]["text"] == guards.WARNING[guards.DESTROY]


def test_remove_lock_warnings_deletes_notice_and_removes_reaction(monkeypatch):
    conn = Conn([(5, CHANNEL_ID, THREAD, "1700000000.000500")])
    monkeypatch.setattr(guard_actions, "session", lambda: session_of(conn))
    client = Slack()

    assert guard_actions.remove_lock_warnings(client) == 1
    assert client.deleted == [{"channel": CHANNEL_ID, "ts": "1700000000.000500"}]
    assert client.reactions_removed == [{"channel": CHANNEL_ID, "timestamp": THREAD, "name": "lock"}]


def test_update_lock_notice_live_lock_updates_message_with_new_end(monkeypatch):
    row = {"channel_id": CHANNEL_ID, "warned_ts": "1700000000.000500", "expires_at": END,
           "reason": "raid"}
    monkeypatch.setattr(guard_actions, "session", lambda: session_of(object()))
    monkeypatch.setattr(guards, "lock_notice_row", lambda conn, guard_id: row)
    monkeypatch.setattr(privileged, "mode", lambda conn=None: privileged.OFF)
    client = Slack()

    assert guard_actions.update_lock_notice(client, 5) == "1700000000.000500"
    assert client.updated[0]["ts"] == "1700000000.000500"
    assert client.updated[0]["text"] == f"*Thread locked* until {short_end(END)} for *raid*"


def test_update_lock_notice_without_live_lock_returns_none(monkeypatch):
    monkeypatch.setattr(guard_actions, "session", lambda: session_of(object()))
    monkeypatch.setattr(guards, "lock_notice_row", lambda conn, guard_id: None)
    client = Slack()

    assert guard_actions.update_lock_notice(client, 5) is None
    assert client.updated == []


def test_lock_notice_query_filters_live_posted_locks():
    assert "kind = 'lock' AND state IN ('warned', 'running') AND warned_ts IS NOT NULL" in guards.LOCK_NOTICE


class Ctx:
    def __init__(self, event, client):
        self.payload = event
        self.client = client


@pytest.fixture
def set_active_guard(monkeypatch):
    monkeypatch.setattr(userbots, "_users", {})
    monkeypatch.setattr(thread_watch, "session", lambda: session_of(object()))
    monkeypatch.setattr(thread_watch.guards, "is_watched", lambda channel_id, ts: True)
    monkeypatch.setattr(thread_watch.guards, "exempt", lambda conn, who, by: False)
    monkeypatch.setattr(thread_watch.guard_actions, "record_guarded_message", lambda conn, guard, who, ts: True)
    monkeypatch.setattr(thread_watch.guard_actions, "delete_guarded_message", lambda client, guard_id, channel_id, ts: True)
    monkeypatch.setattr(thread_watch.guard_actions, "record_and_escalate", lambda guard, who: None)

    def activate(kind):
        row = (5, kind, CHANNEL_ID, THREAD, "warned", MOD, "1700000000.000500", END)
        monkeypatch.setattr(thread_watch.guards, "active_guard", lambda conn, channel_id, ts: row)
    return activate


def reply():
    return {"user": USER_ID, "channel": CHANNEL_ID, "ts": TS, "thread_ts": THREAD, "text": "but nobody answered"}


def test_delete_guarded_thread_message_in_lock_sends_ephemeral_with_reply_text(set_active_guard):
    set_active_guard(guards.LOCK)
    client = Slack()

    thread_watch.delete_guarded_thread_message(Ctx(reply(), client))

    ephemeral_call = client.ephemeral[0]
    assert (ephemeral_call["user"], ephemeral_call["thread_ts"]) == (USER_ID, THREAD)
    assert ephemeral_call["text"] == f"*Thread locked* until {short_end(END)}"
    assert ephemeral_call["blocks"][1]["elements"][0]["elements"][0]["text"] == "but nobody answered"


def test_delete_guarded_thread_message_in_destroy_sends_no_ephemeral(set_active_guard):
    set_active_guard(guards.DESTROY)
    client = Slack()

    thread_watch.delete_guarded_thread_message(Ctx(reply(), client))

    assert client.ephemeral == []
