from bot.nemo import case_actions
from bot.nemo.views import action

CASE_ID = 412
USER_ID = "U1"
MOD = "UMOD"
HELPER = "UHELP"


class Conn:
    def __init__(self, row):
        self.row = row
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        return self.row

    def args_for(self, mark):
        return [args for sql, args in self.executed if mark in sql]


def submission(**over):
    row = {"type_key": "warning", "target_user_id": USER_ID, "reason": "kept at it after being asked to stop"}
    row.update(over)
    return row


def block(built, block_id):
    return next(one for one in built if one.get("block_id") == block_id)


def test_build_blocks_has_solution_resolvers_and_resolve_tick_with_lyla_labels():
    built = action.build_blocks(CASE_ID, submission())
    assert block(built, action.SOLUTION)["label"]["text"] == "How Was This Solved? (Text edition)"
    assert block(built, action.RESOLVERS)["label"]["text"] == "Who Resolved This? (Thank you btw <3)"
    assert block(built, action.RESOLVE)["label"]["text"] == "Resolve Case?"
    assert all(block(built, one)["optional"] for one in (action.SOLUTION, action.RESOLVERS, action.RESOLVE))


def test_build_blocks_leaves_resolve_tick_unticked_by_default():
    built = action.build_blocks(CASE_ID, submission())
    assert "initial_options" not in block(built, action.RESOLVE)["element"]
    assert "initial_options" not in block(built, action.RESOLVERS)["element"]


def test_resolvers_select_loads_options_on_open():
    element = block(action.build_blocks(CASE_ID, submission()), action.RESOLVERS)["element"]
    assert element["type"] == "multi_external_select"
    assert element["min_query_length"] == 0


def test_build_blocks_keeps_entered_solution_resolvers_and_tick():
    built = action.build_blocks(
        CASE_ID,
        submission(solution="removed the post", resolved_by=[MOD, HELPER], resolve_case=True,
                   resolver_labels={MOD: "Mod", HELPER: "Helper"}),
    )
    assert block(built, action.SOLUTION)["element"]["initial_value"] == "removed the post"
    assert block(built, action.RESOLVERS)["element"]["initial_options"] == [
        {"text": {"type": "plain_text", "text": "Mod"}, "value": MOD},
        {"text": {"type": "plain_text", "text": "Helper"}, "value": HELPER},
    ]
    assert block(built, action.RESOLVE)["element"]["initial_options"] == [action.RESOLVE_OPTION]


def test_initial_resolver_options_fall_back_to_the_user_id_without_a_label():
    built = action.build_blocks(CASE_ID, submission(resolved_by=[MOD]))
    assert block(built, action.RESOLVERS)["element"]["initial_options"] == [
        {"text": {"type": "plain_text", "text": MOD}, "value": MOD},
    ]


def test_submitted_values_reads_solution_resolvers_and_tick():
    values = action.submitted_values({"values": {
        action.SOLUTION: {action.SOLUTION: {"value": "  removed the post  "}},
        action.RESOLVERS: {action.RESOLVERS: {"selected_options": [
            {"text": {"type": "plain_text", "text": "Mod"}, "value": MOD},
            {"text": {"type": "plain_text", "text": "Helper"}, "value": HELPER},
        ]}},
        action.RESOLVE: {action.RESOLVE: {"selected_options": [{"value": action.RESOLVE_CASE}]}},
    }})
    assert values["solution"] == "removed the post"
    assert values["resolved_by"] == [MOD, HELPER]
    assert values["resolver_labels"] == {MOD: "Mod", HELPER: "Helper"}
    assert values["resolve_case"] is True


def test_submitted_values_defaults_when_left_empty():
    values = action.submitted_values({"values": {}})
    assert values["solution"] == ""
    assert values["resolved_by"] == []
    assert values["resolver_labels"] == {}
    assert values["resolve_case"] is False


def test_resolver_options_label_with_the_name_and_cap_the_text():
    assert action.resolver_options([(MOD, "Mod"), (HELPER, "x" * 100)]) == [
        {"text": {"type": "plain_text", "text": "Mod"}, "value": MOD},
        {"text": {"type": "plain_text", "text": "x" * 75}, "value": HELPER},
    ]


def test_resolvers_default_to_the_person_logging():
    assert action.resolvers(submission(), MOD) == [MOD]
    assert action.resolvers(submission(resolved_by=[HELPER]), MOD) == [HELPER]


def test_log_blocks_names_resolvers_other_than_the_logger():
    built = action.log_blocks(submission(resolved_by=[MOD, HELPER]), MOD)
    assert built[1]["elements"][0]["text"] == (
        f"Against <@{USER_ID}>, logged by <@{MOD}>, resolved by <@{MOD}>, <@{HELPER}>"
    )


def test_log_blocks_leaves_out_resolvers_when_only_the_logger():
    built = action.log_blocks(submission(resolved_by=[MOD]), MOD)
    assert built[1]["elements"][0]["text"] == f"Against <@{USER_ID}>, logged by <@{MOD}>"


def test_log_blocks_shows_solution():
    built = action.log_blocks(submission(solution="removed the post"), MOD)
    assert built[-1]["elements"][0]["text"] == "*How Was This Solved?* removed the post"


def test_log_action_stores_solution_and_resolvers(monkeypatch):
    monkeypatch.setattr(case_actions.audit, "record", lambda *args, **kwargs: None)
    conn = Conn((55, None, "spam"))
    case_actions.log_action(conn, CASE_ID, submission(solution="removed the post", resolved_by=[HELPER]), MOD)
    args = conn.args_for("INSERT INTO fd.actions")[0]
    assert "removed the post" in args
    assert [HELPER] in args


def test_log_action_resolvers_default_to_the_logger(monkeypatch):
    monkeypatch.setattr(case_actions.audit, "record", lambda *args, **kwargs: None)
    conn = Conn((55, None, "spam"))
    case_actions.log_action(conn, CASE_ID, submission(), MOD)
    args = conn.args_for("INSERT INTO fd.actions")[0]
    assert [MOD] in args
    assert args[9] is None


def test_resolve_tick_dispatches_so_the_modal_can_change():
    built = action.build_blocks(CASE_ID, submission())
    assert block(built, action.RESOLVE)["dispatch_action"] is True


def test_resolve_ticked_without_open_report_adds_no_notify_fields():
    built = action.build_blocks(CASE_ID, submission(resolve_case=True), open_report=False)
    block_ids = {one.get("block_id") for one in built}
    assert action.NOTIFY not in block_ids
    assert action.MESSAGE not in block_ids


def test_resolve_ticked_with_open_report_adds_notify_ticked_and_default_message():
    built = action.build_blocks(CASE_ID, submission(resolve_case=True), open_report=True)
    notify = block(built, action.NOTIFY)
    assert notify["label"]["text"] == "Notify the reporter"
    assert notify["element"]["initial_options"] == [action.NOTIFY_OPTION]
    message = block(built, action.MESSAGE)
    assert message["label"]["text"] == "Message to reporter"
    assert message["element"]["initial_value"] == action.resolve.default_message()


def test_notify_unticked_hides_the_message():
    built = action.build_blocks(
        CASE_ID, submission(resolve_case=True, notify_reporter=False), open_report=True
    )
    assert "initial_options" not in block(built, action.NOTIFY)["element"]
    assert action.MESSAGE not in {one.get("block_id") for one in built}


def test_notify_fields_hidden_until_resolve_is_ticked():
    built = action.build_blocks(CASE_ID, submission(), open_report=True)
    assert action.NOTIFY not in {one.get("block_id") for one in built}


def test_submitted_values_notify_defaults_on_until_the_tick_is_shown():
    assert action.submitted_values({"values": {}})["notify_reporter"] is True
    values = action.submitted_values({"values": {
        action.NOTIFY: {action.NOTIFY: {"selected_options": []}},
        action.MESSAGE: {action.MESSAGE: {"value": "  thanks  "}},
    }})
    assert values["notify_reporter"] is False
    assert values["message"] == "thanks"


def test_requires_refresh_when_resolve_ticked_on_a_reported_case_without_notify_field():
    values = submission(resolve_case=True)
    assert action.requires_refresh(values, {action.RESOLVE}, None, open_report=True)
    assert not action.requires_refresh(values, {action.RESOLVE, action.NOTIFY}, None, open_report=True)
    assert not action.requires_refresh(values, {action.RESOLVE}, None, open_report=False)


def test_resolve_with_action_skips_when_not_ticked():
    assert case_actions.resolve_with_action(Conn(None), CASE_ID, submission(), MOD) is None


def test_resolve_with_action_notifies_reporter_with_the_message(monkeypatch):
    calls = []
    monkeypatch.setattr(case_actions, "resolve_and_notify",
                        lambda conn, case_id, message, by: calls.append((case_id, message, by)) or ("action_taken", 1))
    resolution = case_actions.resolve_with_action(
        Conn((1,)), CASE_ID, submission(resolve_case=True, notify_reporter=True, message="all done"), MOD
    )
    assert resolution == "action_taken"
    assert calls == [(CASE_ID, "all done", MOD)]


def test_resolve_with_action_uses_default_message_when_blank(monkeypatch):
    calls = []
    monkeypatch.setattr(case_actions, "resolve_and_notify",
                        lambda conn, case_id, message, by: calls.append(message) or ("action_taken", 1))
    case_actions.resolve_with_action(
        Conn((1,)), CASE_ID, submission(resolve_case=True, notify_reporter=True, message=None), MOD
    )
    assert calls == [action.resolve.default_message()]


def refuse_notify(*args):
    raise AssertionError("must not notify")


def test_resolve_with_action_without_notify_closes_without_notice(monkeypatch):
    calls = []
    monkeypatch.setattr(case_actions, "close_without_notice",
                        lambda conn, case_id, resolution, by: calls.append((case_id, by)) or "action_taken")
    monkeypatch.setattr(case_actions, "resolve_and_notify", refuse_notify)
    resolution = case_actions.resolve_with_action(
        Conn((1,)), CASE_ID, submission(resolve_case=True, notify_reporter=False), MOD
    )
    assert resolution == "action_taken"
    assert calls == [(CASE_ID, MOD)]


def test_resolve_with_action_without_open_report_closes_without_notice(monkeypatch):
    calls = []
    monkeypatch.setattr(case_actions, "close_without_notice",
                        lambda conn, case_id, resolution, by: calls.append(case_id) or "action_taken")
    case_actions.resolve_with_action(
        Conn(None), CASE_ID, submission(resolve_case=True, notify_reporter=True), MOD
    )
    assert calls == [CASE_ID]
