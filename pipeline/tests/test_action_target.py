import contextlib
import datetime as dt

import pytest

from bot.nemo import case_actions, handlers, memberguards, profile
from bot.nemo.views import action


class Conn:
    def __init__(self, emails=None):
        self.emails = emails or {}
        self.looked_up = []

    def execute(self, sql, args=None):
        self.rows = []
        if sql == case_actions.MEMBERS_WITH_EMAIL:
            self.looked_up.append(args[0])
            self.rows = [(user_id,) for user_id in self.emails.get(args[0], [])]
        return self

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


@pytest.fixture
def denied(monkeypatch):
    refused = set()

    def may(conn, user_id, key, case_id=None):
        return (False, f"No {key}") if key in refused else (True, None)

    monkeypatch.setattr(case_actions.access, "may", may)
    return refused


def typed(text, selected=None):
    return {"selected_user_id": selected, "target_user_id": selected, "target_text": text}


@pytest.mark.parametrize(("text", "parsed"), [
    ("U0123ABCD", ("U0123ABCD", None)),
    ("w0123abcd", ("W0123ABCD", None)),
    ("Someone@Example.org", (None, "someone@example.org")),
    ("U12", (None, None)),
    ("U0123ABCD spam", (None, None)),
    ("someone", (None, None)),
    ("someone@example", (None, None)),
])
def test_typed_target_reads_a_slack_id_or_an_email(text, parsed):
    assert action.typed_target(text) == parsed


def test_resolve_target_takes_a_slack_id_as_is(denied):
    conn = Conn()

    values = case_actions.resolve_target(conn, typed("u0123abcd"), "UMOD")

    assert values["target_user_id"] == "U0123ABCD"
    assert conn.looked_up == []


def test_resolve_target_finds_a_member_by_email(denied):
    conn = Conn({"gone@example.org": ["UGONE"]})

    values = case_actions.resolve_target(conn, typed("Gone@Example.org"), "UMOD")

    assert values["target_user_id"] == "UGONE"
    assert conn.looked_up == ["gone@example.org"]


def test_resolve_target_prefers_the_selected_member(denied):
    conn = Conn({"gone@example.org": ["UGONE"]})

    values = case_actions.resolve_target(conn, typed("gone@example.org", selected="UPICKED"), "UMOD")

    assert values["target_user_id"] == "UPICKED"
    assert conn.looked_up == []


@pytest.mark.parametrize(("text", "emails", "error"), [
    ("nobody@example.org", {}, action.UNKNOWN_EMAIL),
    ("twice@example.org", {"twice@example.org": ["UONE", "UTWO"]}, action.SHARED_EMAIL),
    ("not an id", {}, action.INVALID_TARGET),
])
def test_resolve_target_reports_what_went_wrong(denied, text, emails, error):
    values = case_actions.resolve_target(Conn(emails), typed(text), "UMOD")

    assert values.get("target_user_id") is None
    assert action.validation_errors({**values, "type_key": "warning"}) == {action.TARGET_TEXT: error}


def test_resolve_target_needs_identity_read_for_an_email(denied):
    denied.add("identity.read")
    conn = Conn({"gone@example.org": ["UGONE"]})

    values = case_actions.resolve_target(conn, typed("gone@example.org"), "UMOD")

    assert values.get("target_user_id") is None
    assert values["target_error"] == "No identity.read"
    assert conn.looked_up == []


def test_resolve_target_needs_no_identity_read_for_a_slack_id(denied):
    denied.add("identity.read")

    values = case_actions.resolve_target(Conn(), typed("U0123ABCD"), "UMOD")

    assert values["target_user_id"] == "U0123ABCD"


def test_validation_errors_ask_for_a_member_when_both_fields_are_empty():
    assert action.validation_errors({**typed(""), "type_key": "warning"}) == {action.TARGET: "Select a member"}


def test_build_blocks_keeps_the_typed_text_out_of_the_member_picker():
    values = {**typed("gone@example.org"), "target_user_id": "UGONE", "type_key": "warning"}

    blocks = {block.get("block_id"): block for block in action.build_blocks(49, values)}

    assert "initial_user" not in blocks[action.TARGET]["element"]
    assert blocks[action.TARGET]["optional"] is True
    assert blocks[action.TARGET_TEXT]["label"]["text"] == "Slack ID or email"
    assert blocks[action.TARGET_TEXT]["element"]["initial_value"] == "gone@example.org"


def test_submitted_values_read_the_typed_text():
    state = {"values": {action.TARGET_TEXT: {action.TARGET_TEXT: {"value": "  U0123ABCD "}}}}

    values = action.submitted_values(state)

    assert values["target_text"] == "U0123ABCD"
    assert values["target_user_id"] is None


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


@pytest.fixture
def world(monkeypatch, denied):
    seen = {"logged": [], "denied": denied}

    @contextlib.contextmanager
    def session():
        yield Conn({"gone@example.org": ["UGONE"]})

    monkeypatch.setattr(handlers, "session", session)
    monkeypatch.setattr(handlers, "has_open_report", lambda conn, case_id: False)
    monkeypatch.setattr(memberguards, "guard_status", lambda *args: None)
    monkeypatch.setattr(memberguards, "apply_enforcement", lambda *args: None)
    monkeypatch.setattr(profile, "timezone", lambda client, user_id: dt.UTC)
    monkeypatch.setattr(handlers, "log_action",
                        lambda conn, case_id, values, user_id: seen["logged"].append(values["target_user_id"]))
    monkeypatch.setattr(handlers, "resolve_with_action", lambda *args: None)
    monkeypatch.setattr(handlers, "refresh_card", lambda *args: None)
    monkeypatch.setattr(handlers, "post_action_log", lambda *args: None)
    app = App()
    handlers.register(app)

    def submit(text, ack):
        state = {"values": {
            action.TARGET_TEXT: {action.TARGET_TEXT: {"value": text}},
            action.KIND: {action.KIND: {"selected_option": {"value": "warning"}}},
            action.REASON: {action.REASON: {"value": "spam"}},
        }}
        view = {"private_metadata": "49", "state": state, "blocks": []}
        app.views[action.CALLBACK](ack, {"user": {"id": "UMOD"}}, view, object())

    seen["submit"] = submit
    return seen


def test_log_action_against_a_member_found_by_email(world):
    ack = Ack()

    world["submit"]("gone@example.org", ack)

    assert ack.responses == [{}]
    assert world["logged"] == ["UGONE"]


def test_log_action_with_an_unknown_email_is_refused(world):
    ack = Ack()

    world["submit"]("nobody@example.org", ack)

    assert ack.responses == [{"response_action": "errors", "errors": {action.TARGET_TEXT: action.UNKNOWN_EMAIL}}]
    assert world["logged"] == []
