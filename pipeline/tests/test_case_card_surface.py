import contextlib

import pytest

from bot.nemo import case_actions, case_modal, channel, case_queue, thread_commands
from bot.nemo.surface import case_card as surface
from bot.nemo.views import case_menu as menu
from bot.nemo.views import case_view
from bot.nemo.views import edit

MOD = "UMOD"


class Conn:
    def __init__(self, rows=None):
        self.rows = rows or {}
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        sql = self.executed[-1][0]
        for mark, row in self.rows.items():
            if mark in sql:
                return row
        return None

    def fetchall(self):
        return []


class Client:
    def __init__(self):
        self.opened = []
        self.pushed = []
        self.updated = []

    def views_open(self, **kwargs):
        self.opened.append(kwargs)

    def views_push(self, **kwargs):
        self.pushed.append(kwargs)

    def views_update(self, **kwargs):
        self.updated.append(kwargs)


class Ctx:
    def __init__(self, case_id=49, view=None):
        self.body = {"actions": [{"value": str(case_id)}]}
        self.view = view or {}
        self.client = Client()
        self.user_id = MOD
        self.trigger_id = "T1"
        self.acked = []
        self.ephemerals = []

    def ack(self, **kwargs):
        self.acked.append(kwargs)

    def post_ephemeral(self, message, channel_id=None, thread_ts=None):
        self.ephemerals.append(message)


def submitted(state=None, case_id=49):
    return {"id": "V1", "hash": "H1", "private_metadata": str(case_id), "state": {"values": state or {}}}


def field(block, **value):
    return {block: {block: value}}


@pytest.fixture
def world(monkeypatch):
    seen = {"refreshed": [], "said": [], "resolved": [], "reopened": [], "commands": [], "conn": Conn()}

    @contextlib.contextmanager
    def session():
        yield seen["conn"]

    monkeypatch.setattr(surface, "session", session)
    monkeypatch.setattr(channel, "refresh_card", lambda client, conn, case_id: seen["refreshed"].append(case_id))
    monkeypatch.setattr(case_queue, "refresh_card", lambda client, conn, case_id: None)
    monkeypatch.setattr(channel, "post_line", lambda client, conn, case_id, text: seen["said"].append(text))
    monkeypatch.setattr(channel, "case_url", lambda case_id: f"https://fe/cases/{case_id}")
    monkeypatch.setattr(thread_commands, "current_assignees", lambda conn, case_id: seen.get("assignees", []))
    monkeypatch.setattr(surface.access, "may", lambda conn, user_id, key, case_id=None: seen.get("may", (True, None)))
    monkeypatch.setattr(surface, "after_resolve",
                        lambda client, case_id, resolution, who, post_log=True: seen["resolved"].append((case_id, resolution, post_log)))
    monkeypatch.setattr(surface, "after_reopen", lambda client, case_id, who: seen["reopened"].append(case_id))
    monkeypatch.setattr(edit, "categories", lambda: {"spam": "Spam"})

    def run(verb, args, case_id, user_id):
        seen["commands"].append((verb, args, case_id))
        return seen.get("outcome", thread_commands.accepted_outcome(say=["said it"]))

    monkeypatch.setattr(thread_commands, "run", run)
    return seen


def test_claim_from_card_runs_claim_says_lines_and_refreshes(world):
    ctx = Ctx()

    assert surface.claim_from_card(ctx) == 49

    assert world["commands"] == [(thread_commands.CLAIM, "", 49)]
    assert world["said"] == ["said it"] and world["refreshed"] == [49]


def test_claim_from_card_refusal_is_private(world):
    world["outcome"] = thread_commands.refused_outcome("Already claimed")
    ctx = Ctx()

    surface.claim_from_card(ctx)

    assert ctx.ephemerals == ["Already claimed"] and world["said"] == []


def test_card_buttons_without_case_value_do_nothing(world):
    ctx = Ctx()
    ctx.body = {"actions": [{"value": "x"}]}

    assert surface.claim_from_card(ctx) is None
    assert surface.open_resolve(ctx) is None
    assert surface.open_more(ctx) is None
    assert ctx.client.opened == []


def test_open_resolve_preselects_default_resolution(world, monkeypatch):
    monkeypatch.setattr(case_actions, "default_resolution", lambda conn, case_id: "action_taken")
    ctx = Ctx()

    surface.open_resolve(ctx)

    view = ctx.client.opened[0]["view"]
    assert ctx.client.opened[0]["trigger_id"] == "T1"
    assert view["callback_id"] == menu.RESOLVE_CALLBACK
    assert view["blocks"][0]["element"]["initial_option"]["value"] == "action_taken"


def test_reopen_from_card_reopens_and_redraws(world, monkeypatch):
    monkeypatch.setattr(case_actions, "reopen", lambda conn, case_id, by: True)
    ctx = Ctx()

    assert surface.reopen_from_card(ctx) == 49

    assert world["reopened"] == [49]


def test_reopen_from_card_on_open_case_says_so(world, monkeypatch):
    monkeypatch.setattr(case_actions, "reopen", lambda conn, case_id, by: False)
    ctx = Ctx()

    surface.reopen_from_card(ctx)

    assert ctx.ephemerals == ["Case 49 is already open"] and world["reopened"] == []


class PromptClient(Client):
    def __init__(self):
        super().__init__()
        self.messages = []

    def chat_update(self, **kwargs):
        self.messages.append(kwargs)


class PromptCtx(Ctx):
    def __init__(self):
        super().__init__()
        self.client = PromptClient()
        self.channel_id = "CFIRE"
        self.message_ts = "5.5"


def test_reopen_after_reply_reopens_redraws_and_replaces_prompt(world, monkeypatch):
    monkeypatch.setattr(case_actions, "reopen", lambda conn, case_id, by: True)
    ctx = PromptCtx()

    assert surface.reopen_after_reply(ctx) == 49

    assert world["refreshed"] == [49] and world["said"] == []
    assert ctx.client.messages == [{"channel": "CFIRE", "ts": "5.5", "blocks": [],
                                    "text": "Case 49 reopened after the reporter replied"}]


def test_reopen_after_reply_on_open_case_says_so_and_keeps_prompt(world, monkeypatch):
    monkeypatch.setattr(case_actions, "reopen", lambda conn, case_id, by: False)
    ctx = PromptCtx()

    surface.reopen_after_reply(ctx)

    assert ctx.ephemerals == ["Case 49 is already open"]
    assert world["refreshed"] == [] and ctx.client.messages == []


def test_open_more_builds_menu_from_case_state(world):
    world["assignees"] = ["UONE"]
    world["conn"] = Conn({"resolved_at IS NULL": (True,), "category_key FROM fd.cases": (None,)})
    ctx = Ctx()

    surface.open_more(ctx)

    view = ctx.client.opened[0]["view"]
    assert view["callback_id"] == menu.MENU_CALLBACK
    assert view["blocks"][0]["text"]["text"] == "*Assignees*\n<@UONE>"


def test_claim_from_menu_refusal_refreshes_menu_with_notice(world):
    world["outcome"] = thread_commands.refused_outcome("Already claimed")
    world["conn"] = Conn({"resolved_at IS NULL": (True,), "category_key FROM fd.cases": (None,)})
    ctx = Ctx(view={"id": "V1", "hash": "H1"})

    surface.claim_from_menu(ctx)

    assert ctx.client.updated[0]["view"]["blocks"][0]["elements"][0]["text"] == "Already claimed"
    assert world["said"] == []


def test_unassign_from_menu_with_one_assignee_acts_directly(world):
    world["assignees"] = ["UONE"]
    world["conn"] = Conn({"resolved_at IS NULL": (True,), "category_key FROM fd.cases": (None,)})
    ctx = Ctx(view={"id": "V1", "hash": "H1"})

    surface.open_unassign(ctx)

    assert world["commands"] == [(thread_commands.UNASSIGN, "<@UONE>", 49)]
    assert ctx.client.pushed == [] and ctx.client.updated


def test_unassign_from_menu_with_several_assignees_pushes_picker(world, monkeypatch):
    world["assignees"] = ["UONE", "UTWO"]
    monkeypatch.setattr(surface.profile, "name", lambda client, user_id: f"name {user_id}")
    ctx = Ctx()

    surface.open_unassign(ctx)

    view = ctx.client.pushed[0]["view"]
    assert [one["text"]["text"] for one in view["blocks"][0]["element"]["options"]] == ["name UONE", "name UTWO"]


def test_menu_pushes_assign_note_category_and_merge_modals(world, monkeypatch):
    monkeypatch.setattr(case_actions, "mergeable", lambda conn, preferred: [(49, None, "x")])
    ctx = Ctx()

    world["conn"] = Conn({"category_key FROM fd.cases": ("spam",)})
    surface.open_assign(ctx)
    surface.open_note(ctx)
    surface.open_category(ctx)
    surface.open_merge(ctx)

    assert [one["view"]["callback_id"] for one in ctx.client.pushed] == [
        menu.ASSIGN_CALLBACK, menu.NOTE_CALLBACK, menu.CATEGORY_CALLBACK, "case_merge"]
    assert ctx.client.pushed[2]["view"]["blocks"][0]["element"]["initial_option"]["value"] == "spam"


def test_log_action_opens_existing_modal_for_subjects(world):
    world["conn"] = Conn({"category_key FROM fd.cases": ("spam",)})
    ctx = Ctx()

    surface.open_log_action(ctx)

    assert ctx.client.opened[0]["view"]["callback_id"] == "case_action_log"
    assert ctx.client.opened[0]["view"]["private_metadata"] == "49"


def test_note_target_change_reshapes_modal_keeping_text(world):
    state = {**field(menu.NOTE_TARGET, selected_option={"value": menu.ON_MEMBER}),
             **field(menu.NOTE_TEXT, value="typed")}
    ctx = Ctx(view={**submitted(state), "callback_id": menu.NOTE_CALLBACK})

    surface.reshape_note(ctx)

    view = ctx.client.updated[0]["view"]
    assert [block["block_id"] for block in view["blocks"]] == [menu.NOTE_TARGET, menu.NOTE_MEMBER, menu.NOTE_TEXT]
    assert view["blocks"][2]["element"]["initial_value"] == "typed"


def test_submit_assign_clears_modal_and_says_lines(world):
    ctx = Ctx(view=submitted(field(menu.ASSIGN_TO, selected_users=["U1", "U2"])))

    surface.submit_assign(ctx)

    assert world["commands"] == [(thread_commands.ASSIGN, "<@U1> <@U2>", 49)]
    assert ctx.acked == [{"response_action": "clear"}]
    assert world["said"] == ["said it"] and world["refreshed"] == [49]


def test_submit_assign_without_selection_or_when_refused_shows_error(world):
    empty = Ctx(view=submitted())
    surface.submit_assign(empty)
    assert empty.acked[0]["errors"] == {menu.ASSIGN_TO: surface.NOT_ASSIGNED}

    world["outcome"] = thread_commands.refused_outcome("Already assigned")
    refused = Ctx(view=submitted(field(menu.ASSIGN_TO, selected_users=["U1"])))
    surface.submit_assign(refused)
    assert refused.acked[0]["errors"] == {menu.ASSIGN_TO: "Already assigned"}
    assert world["said"] == []


def test_submit_unassign_runs_unassign_for_selection(world):
    ctx = Ctx(view=submitted(field(menu.UNASSIGN_FROM, selected_options=[{"value": "U1"}])))

    surface.submit_unassign(ctx)

    assert world["commands"] == [(thread_commands.UNASSIGN, "<@U1>", 49)]
    assert ctx.acked == [{"response_action": "clear"}]


def test_submit_note_on_case_saves_case_note(world, monkeypatch):
    saved = []
    monkeypatch.setattr(case_actions, "add_note", lambda conn, case_id, text, by: saved.append((case_id, text)))
    ctx = Ctx(view=submitted(field(menu.NOTE_TEXT, value="watch this")))

    surface.submit_note(ctx)

    assert saved == [(49, "watch this")] and ctx.acked == [{"response_action": "clear"}]


def test_submit_note_on_member_saves_member_note(world, monkeypatch):
    saved = []
    monkeypatch.setattr(case_actions, "member_note", lambda conn, member, text, by: saved.append((member, text)))
    state = {**field(menu.NOTE_TARGET, selected_option={"value": menu.ON_MEMBER}),
             **field(menu.NOTE_MEMBER, selected_user="USUBJECT"), **field(menu.NOTE_TEXT, value="repeat")}
    ctx = Ctx(view=submitted(state))

    surface.submit_note(ctx)

    assert saved == [("USUBJECT", "repeat")]


def test_submit_note_refused_without_capability(world, monkeypatch):
    world["may"] = (False, "No access")
    monkeypatch.setattr(case_actions, "add_note", lambda *args: pytest.fail("saved"))
    ctx = Ctx(view=submitted(field(menu.NOTE_TEXT, value="x")))

    surface.submit_note(ctx)

    assert ctx.acked[0]["errors"] == {menu.NOTE_TEXT: "No access"}


def test_submit_note_on_member_without_member_shows_error(world):
    state = {**field(menu.NOTE_TARGET, selected_option={"value": menu.ON_MEMBER}), **field(menu.NOTE_TEXT, value="x")}
    ctx = Ctx(view=submitted(state))

    surface.submit_note(ctx)

    assert ctx.acked[0]["errors"] == {menu.NOTE_MEMBER: surface.NO_MEMBER}


def test_submit_category_sets_category_and_redraws(world, monkeypatch):
    monkeypatch.setattr(case_actions, "set_category", lambda conn, case_id, key, by: True)
    ctx = Ctx(view=submitted(field(menu.CATEGORY_KEY, selected_option={"value": "spam"})))

    surface.submit_category(ctx)

    assert ctx.acked == [{"response_action": "clear"}] and world["refreshed"] == [49]


def test_submit_category_rejects_unknown_key_and_categorised_case(world, monkeypatch):
    unknown = Ctx(view=submitted(field(menu.CATEGORY_KEY, selected_option={"value": "nope"})))
    surface.submit_category(unknown)
    assert unknown.acked[0]["errors"] == {menu.CATEGORY_KEY: "Select a category"}

    monkeypatch.setattr(case_actions, "set_category", lambda conn, case_id, key, by: False)
    taken = Ctx(view=submitted(field(menu.CATEGORY_KEY, selected_option={"value": "spam"})))
    surface.submit_category(taken)
    assert taken.acked[0]["errors"] == {menu.CATEGORY_KEY: surface.UNCHANGED_CATEGORY}


def resolve_state(message="Thanks"):
    state = field(menu.RESOLUTION, selected_option={"value": "no_action"})
    if message:
        state.update(field(menu.REPORTER_MESSAGE, value=message))
    return state


def test_submit_resolve_with_message_marks_log_pending_and_defers_log(world, monkeypatch):
    marked = []
    monkeypatch.setattr(case_actions, "resolve", lambda conn, case_id, values, by: 1)
    monkeypatch.setattr(case_actions, "mark_resolution_log_pending", lambda conn, case_id, by: marked.append(case_id))
    ctx = Ctx(view=submitted(resolve_state()))

    surface.submit_resolve(ctx)

    assert marked == [49] and ctx.acked == [{"response_action": "clear"}]
    assert world["resolved"] == [(49, "no_action", False)]


def test_submit_resolve_without_message_logs_immediately(world, monkeypatch):
    monkeypatch.setattr(case_actions, "resolve", lambda conn, case_id, values, by: 0)
    ctx = Ctx(view=submitted(resolve_state(message=None)))

    surface.submit_resolve(ctx)

    assert world["resolved"] == [(49, "no_action", True)]


def test_submit_resolve_already_resolved_shows_error(world, monkeypatch):
    monkeypatch.setattr(case_actions, "resolve", lambda conn, case_id, values, by: None)
    ctx = Ctx(view=submitted(resolve_state()))

    surface.submit_resolve(ctx)

    assert ctx.acked[0]["errors"] == {menu.RESOLUTION: "Case 49 is already resolved"}
    assert world["resolved"] == []


def test_submit_resolve_with_message_needs_reply_capability(world, monkeypatch):
    world["may"] = (False, "No reply access")
    monkeypatch.setattr(case_actions, "resolve", lambda *args: pytest.fail("resolved"))
    ctx = Ctx(view=submitted(resolve_state()))

    surface.submit_resolve(ctx)

    assert ctx.acked[0]["errors"] == {menu.REPORTER_MESSAGE: "No reply access"}


def test_submit_resolve_without_resolution_shows_error(world):
    ctx = Ctx(view=submitted())

    surface.submit_resolve(ctx)

    assert ctx.acked[0]["errors"] == {menu.RESOLUTION: "Select a resolution"}


def case_view_of(case_id=49):
    return {"id": "V9", "hash": "H9", "callback_id": case_view.CALLBACK, "private_metadata": str(case_id)}


def test_open_resolve_from_case_view_pushes_view(world, monkeypatch):
    monkeypatch.setattr(case_actions, "default_resolution", lambda conn, case_id: "action_taken")
    ctx = Ctx(view=case_view_of())

    surface.open_resolve(ctx)

    assert ctx.client.opened == [] and ctx.client.pushed[0]["view"]["callback_id"] == menu.RESOLVE_CALLBACK


def test_open_log_action_from_case_view_pushes_view(world):
    ctx = Ctx(view=case_view_of())

    surface.open_log_action(ctx)

    assert ctx.client.opened == [] and len(ctx.client.pushed) == 1


def test_open_log_action_from_message_opens_view(world):
    ctx = Ctx()

    surface.open_log_action(ctx)

    assert ctx.client.pushed == [] and len(ctx.client.opened) == 1


def test_open_more_from_case_view_pushes_view(world):
    ctx = Ctx(view=case_view_of())

    surface.open_more(ctx)

    assert ctx.client.opened == [] and ctx.client.pushed[0]["view"]["callback_id"] == menu.MENU_CALLBACK


def test_claim_from_case_view_updates_view(world, monkeypatch):
    notices = []
    monkeypatch.setattr(case_modal, "build", lambda client, conn, case_id, notice=None: notices.append(notice) or {"type": "modal"})
    ctx = Ctx(view=case_view_of())

    assert surface.claim_from_card(ctx) == 49

    assert ctx.client.updated == [{"view_id": "V9", "hash": "H9", "view": {"type": "modal"}}]
    assert notices == [None] and ctx.ephemerals == []


def test_claim_from_case_view_refusal_becomes_view_notice(world, monkeypatch):
    world["outcome"] = thread_commands.refused_outcome("Already claimed")
    notices = []
    monkeypatch.setattr(case_modal, "build", lambda client, conn, case_id, notice=None: notices.append(notice) or {"type": "modal"})
    ctx = Ctx(view=case_view_of())

    surface.claim_from_card(ctx)

    assert notices == ["Already claimed"] and ctx.ephemerals == []


def test_claim_from_other_view_stays_private(world):
    world["outcome"] = thread_commands.refused_outcome("Already claimed")
    ctx = Ctx(view={"id": "V1", "hash": "H1", "callback_id": menu.MENU_CALLBACK})

    surface.claim_from_card(ctx)

    assert ctx.ephemerals == ["Already claimed"] and ctx.client.updated == []


def test_reopen_from_case_view_updates_view(world, monkeypatch):
    monkeypatch.setattr(case_actions, "reopen", lambda conn, case_id, by: True)
    monkeypatch.setattr(case_modal, "build", lambda client, conn, case_id, notice=None: {"type": "modal"})
    ctx = Ctx(view=case_view_of())

    assert surface.reopen_from_card(ctx) == 49

    assert world["reopened"] == [49] and len(ctx.client.updated) == 1


def test_reopen_from_case_view_on_open_case_updates_view_with_notice(world, monkeypatch):
    monkeypatch.setattr(case_actions, "reopen", lambda conn, case_id, by: False)
    notices = []
    monkeypatch.setattr(case_modal, "build", lambda client, conn, case_id, notice=None: notices.append(notice) or {"type": "modal"})
    ctx = Ctx(view=case_view_of())

    surface.reopen_from_card(ctx)

    assert notices == ["Case 49 is already open"] and ctx.ephemerals == [] and world["reopened"] == []


def test_update_case_view_unknown_case_changes_nothing(world, monkeypatch):
    monkeypatch.setattr(case_modal, "build", lambda client, conn, case_id, notice=None: None)
    ctx = Ctx(view=case_view_of())

    assert surface.update_case_view(ctx, 49) is None

    assert ctx.client.updated == []
