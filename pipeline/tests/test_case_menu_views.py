import pytest

from bot.nemo.views import case_menu as menu
from bot.nemo.views import edit

CATEGORIES = {"harassment": "Harassment", "spam": "Spam"}


@pytest.fixture(autouse=True)
def categories(monkeypatch):
    monkeypatch.setattr(edit, "categories", lambda: CATEGORIES)


def button_ids(view):
    return [one["action_id"] for block in view["blocks"] if block["type"] == "actions" for one in block["elements"]]


def input_ids(view):
    return [block["block_id"] for block in view["blocks"] if block["type"] == "input"]


def test_more_view_unassigned_makes_claim_primary_and_hides_unassign():
    view = menu.more_view(49, [], url="https://fe/cases/49")

    assert button_ids(view) == [menu.MENU_CLAIM, menu.MENU_ASSIGN, menu.MENU_NOTE, menu.MENU_MERGE,
                                menu.MENU_CATEGORY]
    assert view["blocks"][0]["text"]["text"] == "*Assignees*\nNone"
    assert view["blocks"][1]["elements"][0]["style"] == "primary"


def test_more_view_assigned_lists_assignees_and_offers_unassign():
    view = menu.more_view(49, ["UONE", "UTWO"])

    assert view["blocks"][0]["text"]["text"] == "*Assignees*\n<@UONE>, <@UTWO>"
    assert menu.MENU_UNASSIGN in button_ids(view)
    assert "style" not in view["blocks"][1]["elements"][0]


def test_more_view_offers_note_merge_and_category():
    view = menu.more_view(49, [])

    assert button_ids(view)[-3:] == [menu.MENU_NOTE, menu.MENU_MERGE, menu.MENU_CATEGORY]


def test_more_view_links_fire_engine_and_shows_notice_first():
    view = menu.more_view(49, [], url="https://fe/cases/49", notice="Not allowed")

    assert view["blocks"][0] == {"type": "context", "elements": [{"type": "mrkdwn", "text": "Not allowed"}]}
    assert view["blocks"][-1]["elements"][0]["text"] == "<https://fe/cases/49|Open in Fire Engine>"
    assert view["title"]["text"] == "Case 49"
    assert "submit" not in view


def test_assign_view_preselects_current_assignees():
    view = menu.assign_view(49, ["UONE"])
    element = view["blocks"][0]["element"]

    assert element["type"] == "multi_users_select"
    assert element["initial_users"] == ["UONE"]
    assert view["submit"]["text"] == "Assign"


def test_unassign_view_lists_assignees_by_name():
    view = menu.unassign_view(49, [("UONE", "One"), ("UTWO", "Two")])
    options = view["blocks"][0]["element"]["options"]

    assert [(one["text"]["text"], one["value"]) for one in options] == [("One", "UONE"), ("Two", "UTWO")]


def test_note_view_on_case_has_only_text_block():
    view = menu.note_view(49)

    assert input_ids(view) == [menu.NOTE_TARGET, menu.NOTE_TEXT]
    assert view["blocks"][0]["element"]["initial_option"]["value"] == menu.ON_CASE
    assert view["blocks"][0]["dispatch_action"] is True


def test_note_view_on_member_adds_member_picker_and_keeps_text():
    view = menu.note_view(49, on_member=True, member="USUBJECT", text="kept")

    assert input_ids(view) == [menu.NOTE_TARGET, menu.NOTE_MEMBER, menu.NOTE_TEXT]
    assert view["blocks"][1]["element"]["initial_user"] == "USUBJECT"
    assert view["blocks"][2]["element"]["initial_value"] == "kept"
    assert view["blocks"][0]["element"]["initial_option"]["value"] == menu.ON_MEMBER


def test_category_view_lists_active_categories():
    view = menu.category_view(49)
    options = view["blocks"][0]["element"]["options"]

    assert [one["value"] for one in options] == ["harassment", "spam"]
    assert "initial_option" not in view["blocks"][0]["element"]
    assert view["submit"]["text"] == "Save"


def test_category_view_preselects_current_category():
    view = menu.category_view(49, "spam")

    assert view["blocks"][0]["element"]["initial_option"]["value"] == "spam"


def test_resolve_view_excludes_duplicate_and_prefills_reporter_message():
    view = menu.resolve_view(49, "no_action")
    resolution, message = view["blocks"]

    assert [one["value"] for one in resolution["element"]["options"]] == [
        "action_taken", "no_action", "not_conduct"]
    assert resolution["element"]["initial_option"]["value"] == "no_action"
    assert message["optional"] is True
    assert message["element"]["initial_value"].startswith("Thanks for reporting")


def test_every_view_respects_slack_modal_limits():
    for view in (menu.more_view(49, ["U1"]), menu.assign_view(49), menu.unassign_view(49, [("U1", "x" * 200)]),
                 menu.note_view(49), menu.category_view(49), menu.resolve_view(49)):
        assert len(view["title"]["text"]) <= 24
        assert len(view["close"]["text"]) <= 24
        assert len(view["private_metadata"]) <= 3000
        has_input = any(block["type"] == "input" for block in view["blocks"])
        assert (not has_input) or "submit" in view
        for block in view["blocks"]:
            for one in block.get("element", {}).get("options", []):
                assert len(one["text"]["text"]) <= 75


def state(**blocks):
    return {"values": {key: {key: value} for key, value in blocks.items()}}


def test_parsers_read_submitted_state():
    assert menu.assign_values(state(**{menu.ASSIGN_TO: {"selected_users": ["U1", "U2"]}})) == ["U1", "U2"]
    assert menu.unassign_values(state(**{menu.UNASSIGN_FROM: {"selected_options": [{"value": "U1"}]}})) == ["U1"]
    assert menu.category_value(state(**{menu.CATEGORY_KEY: {"selected_option": {"value": "spam"}}})) == "spam"
    assert menu.assign_values({}) == []
    assert menu.category_value({}) is None


def test_note_values_reads_target_member_and_trimmed_text():
    values = menu.note_values(state(**{
        menu.NOTE_TARGET: {"selected_option": {"value": menu.ON_MEMBER}},
        menu.NOTE_MEMBER: {"selected_user": "U1"},
        menu.NOTE_TEXT: {"value": "  words  "},
    }))

    assert values == {"on_member": True, "member": "U1", "text": "words"}
    assert menu.note_values({})["on_member"] is False


def test_resolve_values_notify_only_with_message():
    chosen = state(**{menu.RESOLUTION: {"selected_option": {"value": "no_action"}}})
    assert menu.resolve_values(chosen)["notify_reporter"] is False

    spoken = state(**{menu.RESOLUTION: {"selected_option": {"value": "no_action"}},
                      menu.REPORTER_MESSAGE: {"value": "Thanks"}})
    assert menu.resolve_values(spoken) == {
        "resolution": "no_action", "member_note": None, "message": "Thanks", "notify_reporter": True}
