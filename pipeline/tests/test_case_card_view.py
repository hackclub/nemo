import datetime as dt

import pytest

from bot.nemo.views import case_card

UPDATED = dt.datetime(2026, 10, 17, 12, 0, tzinfo=dt.UTC)


def case(**over):
    row = {"case_id": 49, "category_key": "harassment", "subjects": ["USUBJECT"], "assignees": [],
           "resolved_at": None, "resolution": None, "actions": [], "updated_at": UPDATED}
    row.update(over)
    return row


def button_ids(row):
    return [one["action_id"] for one in case_card.card_block(row)["actions"]]


def primary_of(row):
    return [one["action_id"] for one in case_card.card_block(row)["actions"] if one.get("style") == "primary"]


def test_state_distinguishes_open_resolved_and_merged():
    assert case_card.state(case()) == case_card.OPEN
    assert case_card.state(case(resolved_at=UPDATED, resolution="no_action")) == case_card.RESOLVED
    assert case_card.state(case(resolved_at=UPDATED, resolution="duplicate")) == case_card.MERGED


def test_title_names_case_number_and_state():
    assert case_card.title(case()) == "Case 49, open"
    assert case_card.title(case(resolved_at=UPDATED, resolution="action_taken")) == "Case 49, resolved"
    assert case_card.title(case(resolved_at=UPDATED, resolution="duplicate")) == "Case 49, merged"


def test_body_open_unassigned_lists_subject_then_unassigned():
    assert case_card.body_text(case()) == "<@USUBJECT>, unassigned"


def test_body_open_assigned_lists_every_assignee():
    row = case(assignees=["UONE", "UTWO"])

    assert case_card.body_text(row) == "<@USUBJECT>, assigned to <@UONE> and <@UTWO>"


def test_body_without_subject_starts_with_capital():
    assert case_card.body_text(case(subjects=[])) == "Unassigned"


def test_body_resolved_names_resolver():
    row = case(resolved_at=UPDATED, resolution="action_taken", resolved_by="UMOD")

    assert case_card.body_text(row) == "<@USUBJECT>, resolved by <@UMOD>"


def test_body_merged_links_target_case():
    row = case(resolved_at=UPDATED, resolution="duplicate", resolved_by="UMOD", duplicate_of=52,
               duplicate_url="https://fe/cases/52")

    assert case_card.body_text(row) == "<@USUBJECT>, merged into <https://fe/cases/52|case 52> by <@UMOD>"


def test_body_caps_people_listed():
    row = case(subjects=["U1", "U2", "U3", "U4", "U5"])

    assert case_card.body_text(row).startswith("<@U1>, <@U2>, <@U3> and 2 more, unassigned")


def test_subtext_lists_actions_with_counts_and_updated_token():
    row = case(actions=["shush", "warning", "warning"])

    assert case_card.subtext(row) == f"Shush, Warning (2), updated <!date^{int(UPDATED.timestamp())}^{{ago}}|{case_card.short_end(UPDATED)}>"


def test_subtext_resolved_leads_with_resolution_label():
    row = case(resolved_at=UPDATED, resolution="no_action")

    assert case_card.subtext(row).startswith("No action needed, updated ")


def test_subtext_without_updated_at_or_actions_is_empty():
    assert case_card.subtext(case(updated_at=None)) == ""


def test_subtitle_is_category_label_and_absent_without_category():
    assert case_card.subtitle(case()) == "harassment"
    assert "subtitle" not in case_card.card_block(case(category_key=None))


def test_icon_present_only_with_subject_icon():
    assert "icon" not in case_card.card_block(case())
    block = case_card.card_block(case(subject_icon="https://img/u.png"))

    assert block["icon"] == {"type": "image", "image_url": "https://img/u.png", "alt_text": "Subject"}


@pytest.mark.parametrize(("row", "ids", "primary"), [
    (case(), ["case_log_action", "case_more", "case_claim"], ["case_claim"]),
    (case(assignees=["UMOD"]), ["case_log_action", "case_more", "case_resolve"], ["case_resolve"]),
    (case(resolved_at=UPDATED, resolution="no_action"), ["case_more", "case_reopen"], ["case_reopen"]),
    (case(resolved_at=UPDATED, resolution="duplicate"), ["case_more", "case_unmerge"], []),
])
def test_buttons_follow_case_state(row, ids, primary):
    assert button_ids(row) == ids
    assert primary_of(row) == primary


def test_unmerge_button_asks_for_confirmation_naming_both_cases():
    block = case_card.card_block(case(resolved_at=UPDATED, resolution="duplicate", duplicate_of=23))
    unmerge = block["actions"][-1]

    assert unmerge["text"]["text"] == "Unmerge"
    assert "style" not in unmerge
    assert unmerge["value"] == "49"
    assert unmerge["confirm"]["text"]["text"] == "Unmerge case 49 from case 23?"
    assert unmerge["confirm"]["confirm"]["text"] == "Unmerge"
    assert unmerge["confirm"]["style"] == "danger"


def test_reopen_button_asks_for_confirmation():
    block = case_card.card_block(case(resolved_at=UPDATED, resolution="no_action"))
    reopen = block["actions"][-1]

    assert reopen["confirm"]["confirm"]["text"] == "Reopen"
    assert reopen["value"] == "49"


def test_render_carries_fallback_text_with_category():
    rendered = case_card.render(case())

    assert rendered["text"] == "Case 49, open, harassment"
    assert rendered["blocks"][0]["type"] == "card"


def test_digest_changes_with_assignment_and_not_with_repeat():
    assert case_card.digest(case()) == case_card.digest(case())
    assert case_card.digest(case()) != case_card.digest(case(assignees=["UMOD"]))
    assert case_card.digest(case()) != case_card.digest(case(actions=["warning"]))


def test_text_fields_stay_within_slack_limits():
    row = case(subjects=[f"U{n:09d}" for n in range(30)], assignees=[f"W{n:09d}" for n in range(30)],
               actions=[f"kind_{n}" for n in range(60)])
    block = case_card.card_block(row)

    assert len(block["title"]["text"]) <= 150
    assert len(block["body"]["text"]) <= 200
    assert len(block["subtext"]["text"]) <= 200
