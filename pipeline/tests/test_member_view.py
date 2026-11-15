import datetime as dt

from bot.core.formatting import short_end
from bot.nemo.views import case_menu, member_view

AT = dt.datetime(2026, 10, 17, 12, 0, tzinfo=dt.UTC)
URL = "https://fe/members/UM"


def url_of(case_id):
    return f"https://fe/cases/{case_id}"


def slack_of(case_id):
    return f"https://slack/{case_id}"


def entry(**over):
    row = {"type_key": "shush", "case_id": 44, "performed_by": "UMOD", "performed_at": AT,
           "expires_at": None, "reason": "spam", "reversed_at": None, "reversed_by": None,
           "reversal_reason": None, "channel_id": None}
    row.update(over)
    return row


def note(**over):
    row = {"author": "UMOD", "body": "likely an alternate", "created_at": AT}
    row.update(over)
    return row


def build(actions=(), notes=(), url=URL, can_note=True, active="Nothing active", counts="No record"):
    return member_view.build_view("UM", active, counts, list(actions), list(notes), url, can_note, url_of)


def types(view):
    return [one["type"] for one in view["blocks"]]


def test_build_view_sets_modal_identity():
    view = build()

    assert view["callback_id"] == member_view.CALLBACK
    assert view["private_metadata"] == "UM"
    assert view["title"]["text"] == "Member record"


def test_build_view_leads_with_member_and_active_line_then_counts():
    view = build(active="Shush until 25 Oct, case 44", counts="9 cases")

    assert view["blocks"][0]["text"]["text"] == "*<@UM>*  Shush until 25 Oct, case 44"
    assert view["blocks"][1]["elements"][0]["text"] == "9 cases"


def test_build_view_has_no_card_or_image():
    view = build(actions=[entry()], notes=[note()])

    assert "card" not in types(view) and "image" not in str(view)


def test_build_view_without_actions_or_notes_omits_sections():
    assert "header" not in types(build())


def test_build_view_sections_follow_actions_then_notes():
    view = build(actions=[entry()], notes=[note()])

    assert [one["text"]["text"] for one in view["blocks"] if one["type"] == "header"] == ["Actions", "Notes"]


def test_action_text_links_case_and_shows_reason_and_actor():
    text = member_view.action_text(entry(), url_of)

    assert text.startswith("*Shush*  <https://fe/cases/44|case 44>\nspam _<@UMOD>, ")


def test_action_text_links_case_slack_thread_after_fire_engine():
    text = member_view.action_text(entry(), url_of, slack_of)

    assert text.startswith("*Shush*  <https://fe/cases/44|case 44> (<https://slack/44|Slack>)\nspam _<@UMOD>, ")


def test_action_text_without_slack_thread_keeps_fire_engine_link_only():
    text = member_view.action_text(entry(), url_of, lambda case_id: None)

    assert text.startswith("*Shush*  <https://fe/cases/44|case 44>\nspam _<@UMOD>, ")


def test_build_view_passes_slack_threads_to_every_action():
    view = member_view.build_view("UM", "Nothing active", "No record", [entry(), entry(case_id=45)], [], URL,
                                  True, url_of, slack_of)
    text = str(view["blocks"])

    assert "(<https://slack/44|Slack>)" in text and "(<https://slack/45|Slack>)" in text


def test_action_text_without_case_url_uses_plain_case_number():
    assert "case 44" in member_view.action_text(entry()) and "<https" not in member_view.action_text(entry())


def test_action_text_shows_end_for_live_action():
    assert f", ends {short_end(AT)}" in member_view.action_text(entry(expires_at=AT), url_of)


def test_action_text_reversed_shows_reverser_and_reason_not_end():
    text = member_view.action_text(entry(expires_at=AT, reversed_at=AT, reversed_by="UREV", reversal_reason="mistake"), url_of)

    assert ", reversed\n" in text and "ends" not in text
    assert "_Reversed by <@UREV>: mistake, " in text


def test_action_text_reversed_without_reason_omits_colon():
    text = member_view.action_text(entry(reversed_at=AT, reversed_by="UREV"), url_of)

    assert "_Reversed by <@UREV>, " in text


def test_action_text_without_reason_keeps_actor_line():
    text = member_view.action_text(entry(reason=None), url_of)

    assert text.split("\n")[1].startswith("_<@UMOD>")


def test_action_text_channel_ban_names_channel():
    assert " in <#CLOUNGE>" in member_view.action_text(entry(type_key="channel_ban", channel_id="CLOUNGE"), url_of)


def test_action_text_escapes_reason():
    assert "&lt;b&gt;" in member_view.action_text(entry(reason="<b>"), url_of)


def test_note_text_shows_author_and_body():
    assert member_view.note_text(note()).startswith("*<@UMOD>*  _") and "likely an alternate" in member_view.note_text(note())


def test_build_view_buttons_include_add_note_when_allowed():
    buttons = build()["blocks"][-1]["elements"]

    assert [one["action_id"] for one in buttons] == [member_view.ADD_NOTE, member_view.OPEN_WEB]
    assert buttons[0]["value"] == "UM" and buttons[1]["url"] == URL


def test_build_view_without_note_permission_omits_add_note():
    buttons = build(can_note=False)["blocks"][-1]["elements"]

    assert [one["action_id"] for one in buttons] == [member_view.OPEN_WEB]


def test_build_view_without_url_or_permission_has_no_actions_block():
    assert "actions" not in types(build(url=None, can_note=False))


def test_build_view_text_sections_fit_slack_limit():
    actions = [entry(reason="r" * 2000, reversal_reason="x" * 400) for _ in range(3)]
    notes = [note(body="n" * 5000) for _ in range(2)]

    view = build(actions=actions, notes=notes)

    assert all(len(one["text"]["text"]) <= 3000 for one in view["blocks"] if one["type"] == "section")


def test_note_view_carries_member_and_text_input():
    view = member_view.note_view("UM")

    assert view["callback_id"] == member_view.NOTE_CALLBACK and view["private_metadata"] == "UM"
    assert view["blocks"][0]["element"]["action_id"] == member_view.NOTE_TEXT
    assert view["blocks"][0]["element"]["max_length"] == case_menu.TEXT_LIMIT
    assert view["submit"]["text"] == "Add"
