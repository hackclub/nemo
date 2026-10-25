import contextlib
import datetime as dt

import pytest

from bot.nemo import handlers, memberguards, profile
from bot.nemo.views import action


class App:
    def __init__(self):
        self.views = {}

    def action(self, key):
        return lambda fn: fn

    def view(self, key):
        def register(fn):
            self.views[key] = fn
            return fn
        return register


class Ack:
    def __init__(self):
        self.responses = []

    def __call__(self, **kwargs):
        self.responses.append(kwargs)


class Conn:
    def execute(self, sql, args=None):
        return self

    def fetchone(self):
        return None


def log_state(kind):
    values = {
        action.TARGET: {action.TARGET: {"selected_user": "UTARGET"}},
        action.KIND: {action.KIND: {"selected_option": {"value": kind}}},
        action.REASON: {action.REASON: {"value": "spam"}},
    }
    return {"private_metadata": "49", "state": {"values": values}, "blocks": []}


@pytest.fixture
def world(monkeypatch):
    seen = {"asked": [], "denied": set(), "logged": []}

    @contextlib.contextmanager
    def session():
        yield Conn()

    def may(conn, user_id, key, case_id=None):
        seen["asked"].append(key)
        return (False, f"No {key}") if key in seen["denied"] else (True, None)

    monkeypatch.setattr(handlers, "session", session)
    monkeypatch.setattr(handlers.access, "may", may)
    monkeypatch.setattr(memberguards, "guard_status", lambda *args: None)
    monkeypatch.setattr(memberguards, "apply_enforcement", lambda *args: None)
    monkeypatch.setattr(profile, "timezone", lambda client, user_id: dt.UTC)
    monkeypatch.setattr(handlers, "log_action", lambda conn, case_id, values, user_id: seen["logged"].append(values["type_key"]))
    monkeypatch.setattr(handlers, "resolve_with_action", lambda *args: None)
    monkeypatch.setattr(handlers, "refresh_card", lambda *args: None)
    monkeypatch.setattr(handlers, "post_action_log", lambda *args: None)
    app = App()
    handlers.register(app)
    seen["submit"] = lambda kind, ack: app.views[action.CALLBACK](ack, {"user": {"id": "UMOD"}}, log_state(kind), object())
    return seen


def test_log_ban_without_member_deactivate_is_refused(world):
    world["denied"] = {"member.deactivate"}
    ack = Ack()

    world["submit"]("perma_ban", ack)

    assert ack.responses == [{"response_action": "errors", "errors": {action.KIND: "No member.deactivate"}}]
    assert world["logged"] == []


def test_log_ban_with_member_deactivate_is_logged(world):
    ack = Ack()

    world["submit"]("indef_ban", ack)

    assert "member.deactivate" in world["asked"]
    assert world["logged"] == ["indef_ban"]


def test_log_warning_does_not_ask_for_member_deactivate(world):
    world["denied"] = {"member.deactivate"}
    ack = Ack()

    world["submit"]("warning", ack)

    assert "member.deactivate" not in world["asked"]
    assert world["logged"] == ["warning"]


@pytest.mark.parametrize(("kind", "expected"), [
    ("temp_ban", True), ("indef_ban", True), ("perma_ban", True), ("shush", False), ("warning", False),
])
def test_deactivates_matches_deactivation_guard_kinds(kind, expected):
    assert action.deactivates(kind) is expected
