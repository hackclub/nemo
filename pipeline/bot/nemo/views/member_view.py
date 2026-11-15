from bot.core.formatting import escape, short_end
from bot.nemo.views import action, case_menu, case_view, lengths
from bot.nemo.views.lines import slack_link

CALLBACK = "member_view"
NOTE_CALLBACK = "member_note"
ADD_NOTE = "member_add_note"
OPEN_WEB = "open_record"
NOTE_TEXT = "member_note_text"

NOTE_LIMIT = case_view.NOTE_LIMIT
REASON_LIMIT = case_view.REASON_LIMIT
TEXT_LIMIT = case_menu.TEXT_LIMIT


def case_ref(case_id, url_of, slack_of=None):
    url = url_of(case_id) if url_of else None
    linked = f"<{url}|case {case_id}>" if url else f"case {case_id}"
    return linked + slack_link(slack_of(case_id) if slack_of else None)


def action_text(entry, url_of=None, slack_of=None):
    head = f"*{escape(action.label(entry['type_key']))}*  {case_ref(entry['case_id'], url_of, slack_of)}"
    if entry.get("channel_id"):
        head += f" in <#{entry['channel_id']}>"
    reversed_at = entry.get("reversed_at")
    if reversed_at:
        head += ", reversed"
    elif entry.get("expires_at"):
        head += f", ends {escape(short_end(entry['expires_at']))}"

    reason = escape(case_view.shorten(entry["reason"], REASON_LIMIT)) if entry.get("reason") else ""
    if reversed_at:
        why = f": {escape(entry['reversal_reason'])}" if entry.get("reversal_reason") else ""
        tail = f"_Reversed by <@{entry['reversed_by']}>{why}, {case_view.ago(reversed_at)}_"
    else:
        tail = f"_<@{entry['performed_by']}>, {case_view.ago(entry['performed_at'])}_"
    return f"{head}\n{reason} {tail}" if reason else f"{head}\n{tail}"


def note_text(note):
    return f"*<@{note['author']}>*  _{case_view.ago(note['created_at'])}_\n{escape(case_view.shorten(note['body'], NOTE_LIMIT))}"


def button(action_id, text, value=None, url=None):
    built = {"type": "button", "action_id": action_id, "text": lengths.plain(text)}
    if value:
        built["value"] = value
    if url:
        built["url"] = url
    return built


def build_view(user_id, active, counts, actions, notes, url=None, can_note=False, url_of=None, slack_of=None):
    blocks = [case_view.section(f"*<@{user_id}>*  {active}"), case_view.context(counts)]
    if actions:
        blocks.append(case_view.header("Actions"))
        blocks.append(case_view.section("\n\n".join(action_text(one, url_of, slack_of) for one in actions)))
    if notes:
        blocks.append(case_view.header("Notes"))
        blocks.append(case_view.section("\n\n".join(note_text(one) for one in notes)))

    buttons = []
    if can_note:
        buttons.append(button(ADD_NOTE, "Add note", user_id))
    if url:
        buttons.append(button(OPEN_WEB, "Open in Fire Engine", url=url))
    if buttons:
        blocks.append({"type": "actions", "elements": buttons})

    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": user_id,
        "title": lengths.plain("Member record"),
        "close": lengths.plain("Close"),
        "blocks": blocks,
    }


def note_view(user_id):
    element = {"type": "plain_text_input", "action_id": NOTE_TEXT, "multiline": True, "max_length": TEXT_LIMIT}
    return case_menu.modal(
        NOTE_CALLBACK, user_id, "Note", [case_menu.field(NOTE_TEXT, "Note", element)], "Add",
    )
