import contextlib
import datetime as dt

from bot.nemo import case_actions, handlers, memberguards, profile
from bot.nemo.views import action


def submission(**over):
    row = {"type_key": "temp_ban", "target_user_id": "U1", "reason": "spamming", "also": []}
    row.update(over)
    return row


def block(blocks, block_id):
    return next((one for one in blocks if one.get("block_id") == block_id), None)


def test_additional_keys_are_the_types_with_no_guard_end_channel_or_thread():
    assert action.additional_keys() == ["warning", "dm", "deleted_messages"]


def test_also_block_follows_the_action_and_leaves_out_the_chosen_type():
    blocks = action.build_blocks(1, submission(type_key="warning"))
    ids = [one.get("block_id") for one in blocks]

    assert ids.index(action.ALSO) == ids.index(action.KIND) + 1
    also = block(blocks, action.ALSO)
    assert also["optional"] is True
    assert also["label"]["text"] == "Additional actions"
    assert [one["value"] for one in also["element"]["options"]] == ["dm", "deleted_messages"]


def test_also_block_keeps_ticked_types_across_redraws():
    also = block(action.build_blocks(1, submission(also=["dm"])), action.ALSO)

    assert [one["value"] for one in also["element"]["initial_options"]] == ["dm"]


def test_also_block_is_left_out_for_a_locked_thread():
    assert block(action.build_blocks(1, submission(type_key="locked_thread")), action.ALSO) is None


def test_submitted_values_read_the_ticked_types():
    state = {"values": {action.ALSO: {action.ALSO: {"selected_options": [{"value": "dm"}, {"value": "warning"}]}}}}

    assert action.submitted_values(state)["also"] == ["dm", "warning"]


def test_also_keys_keep_only_additional_types_other_than_the_action_in_table_order():
    values = submission(type_key="warning", also=["dm", "warning", "shush", "deleted_messages", "bogus"])

    assert action.also_keys(values) == ["dm", "deleted_messages"]


def test_header_and_labels_name_every_type():
    assert action.header_text(submission(also=["dm"])) == "Temporary ban, DM"
    assert action.header_text(submission(type_key="channel_ban", channel_id="CGEN", also=["warning"]),
                              channel_name="general") == "Channel ban from #general, Warning"
    assert action.labels(submission(type_key="warning", also=["dm", "deleted_messages"])) == \
        "Warning, DM, Deleted messages"


class Recorder:
    def __init__(self):
        self.executed = []
        self.next_id = 100

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        self.last = sql
        return self

    def fetchone(self):
        if self.last == case_actions.LOG_ACTION:
            self.next_id += 1
            return (self.next_id, dt.datetime(2026, 11, 15, tzinfo=dt.UTC), "spam")
        return None

    def ran(self, sql):
        return [args for statement, args in self.executed if statement == sql]


def test_log_additional_logs_each_extra_type_without_end_or_channel_and_groups_them():
    conn = Recorder()

    added = case_actions.log_additional(conn, 49, submission(also=["dm", "warning"]), "UMOD", 77)

    assert added == [101, 102]
    inserts = conn.ran(case_actions.LOG_ACTION)
    assert [args[1] for args in inserts] == ["warning", "dm"]
    assert all(args[6] is None and args[7].obj == {} for args in inserts)
    assert all(args[8] == "spamming" for args in inserts)
    assert conn.ran(case_actions.GROUP_ACTIONS) == [(77, [77, 101, 102])]
    performed = [args for sql, args in conn.executed if "INSERT INTO fd.audit" in sql]
    assert [(row[3], row[4], row[6].obj["type_key"], row[6].obj["group_id"]) for row in performed] == \
        [(101, "performed", "warning", 77), (102, "performed", "dm", 77)]


def test_log_additional_without_extra_types_or_member_does_nothing():
    conn = Recorder()

    assert case_actions.log_additional(conn, 49, submission(), "UMOD", 77) == []
    assert case_actions.log_additional(conn, 49, submission(also=["dm"], target_user_id=None), "UMOD", 77) == []
    assert conn.executed == []


class Ack:
    def __init__(self):
        self.responses = []

    def __call__(self, **kwargs):
        self.responses.append(kwargs)


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


class Conn:
    def execute(self, sql, args=None):
        return self

    def fetchone(self):
        return None


def test_submitting_the_modal_logs_the_extra_types_after_the_main_action(monkeypatch):
    calls = []

    @contextlib.contextmanager
    def session():
        yield Conn()

    monkeypatch.setattr(handlers, "session", session)
    monkeypatch.setattr(handlers.access, "may", lambda conn, user_id, key, case_id=None: (True, None))
    monkeypatch.setattr(memberguards, "guard_status", lambda *args: None)
    monkeypatch.setattr(memberguards, "apply_enforcement", lambda *args: calls.append("enforced"))
    monkeypatch.setattr(profile, "timezone", lambda client, user_id: dt.UTC)
    monkeypatch.setattr(handlers, "log_action", lambda conn, case_id, values, user_id: calls.append("logged") or 77)
    monkeypatch.setattr(handlers, "log_additional",
                        lambda conn, case_id, values, user_id, main_id: calls.append(("also", values["also"], main_id)))
    monkeypatch.setattr(handlers, "resolve_with_action", lambda *args: None)
    monkeypatch.setattr(handlers, "refresh_card", lambda *args: None)
    monkeypatch.setattr(handlers, "post_action_log", lambda *args: None)
    app = App()
    handlers.register(app)
    values = {
        action.TARGET: {action.TARGET: {"selected_user": "UTARGET"}},
        action.KIND: {action.KIND: {"selected_option": {"value": "warning"}}},
        action.ALSO: {action.ALSO: {"selected_options": [{"value": "dm"}]}},
        action.REASON: {action.REASON: {"value": "spam"}},
    }
    view = {"private_metadata": "49", "state": {"values": values},
            "blocks": [{"block_id": action.KIND}, {"block_id": action.ALSO}]}
    ack = Ack()

    app.views[action.CALLBACK](ack, {"user": {"id": "UMOD"}}, view, object())

    assert calls == ["logged", "enforced", ("also", ["dm"], 77)]
