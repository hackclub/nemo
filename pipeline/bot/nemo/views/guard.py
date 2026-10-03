import json

from bot.core import richtext

DESTROY_CALLBACK = "thread_destroy"
LOCK_CALLBACK = "thread_lock"

REASON = "guard_reason"
UNTIL = "guard_until"
NOTE = "guard_note"
NOTE_TEXT = "guard_note_text"

REASON_LIMIT = 500
NOTE_LABEL = "Leave an FD note"
TITLE_LIMIT = 24

DESTROY_WARNING = "Kept on the case record, then deleted from Slack. Cannot be undone."

LOCK_WARNING = "Replies are removed until the lock lifts."

ASIDE = "Anyone who keeps posting is signed out of Slack."


def metadata(channel_id, thread_ts):
    return json.dumps({"channel_id": channel_id, "thread_ts": thread_ts})


def opened(view):
    try:
        values = json.loads(view.get("private_metadata") or "{}")
    except ValueError:
        return None, None
    return values.get("channel_id"), values.get("thread_ts")


def reason_block(value=None):
    element = {
        "type": "plain_text_input",
        "action_id": REASON,
        "multiline": True,
        "max_length": REASON_LIMIT,
    }
    if value:
        element["initial_value"] = value
    return {
        "type": "input",
        "block_id": REASON,
        "label": {"type": "plain_text", "text": "Why"},
        "element": element,
    }


def note_option():
    return {"text": {"type": "mrkdwn", "text": NOTE_LABEL}, "value": "on"}


def note_block(on):
    element = {"type": "checkboxes", "action_id": NOTE, "options": [note_option()]}
    if on:
        element["initial_options"] = [note_option()]
    return {
        "type": "input",
        "block_id": NOTE,
        "optional": True,
        "dispatch_action": True,
        "label": {"type": "plain_text", "text": "Note"},
        "element": element,
    }


def note_text_block(value=None):
    element = {
        "type": "rich_text_input",
        "action_id": NOTE_TEXT,
        "min_lines": 4,
        "placeholder": {"type": "plain_text", "text": "what you did and why"},
    }
    if value:
        element["initial_value"] = value
    return {
        "type": "input",
        "block_id": NOTE_TEXT,
        "label": {"type": "plain_text", "text": "What it says"},
        "element": element,
    }


def section_block(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}}


def context_block():
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": ASIDE}]}


def destroy_view(channel_id, thread_ts, values=None):
    values = values or {}
    blocks = [
        section_block(DESTROY_WARNING),
        context_block(),
        reason_block(values.get("reason")),
        note_block(values.get("note")),
    ]
    if values.get("note"):
        blocks.append(note_text_block(values.get("note_body")))

    return {
        "type": "modal",
        "callback_id": DESTROY_CALLBACK,
        "private_metadata": metadata(channel_id, thread_ts),
        "title": {"type": "plain_text", "text": "Destroy thread"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Destroy it"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": blocks,
    }


def lock_view(channel_id, thread_ts):
    return {
        "type": "modal",
        "callback_id": LOCK_CALLBACK,
        "private_metadata": metadata(channel_id, thread_ts),
        "title": {"type": "plain_text", "text": "Lock thread"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Lock it"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": [
            section_block(LOCK_WARNING),
            context_block(),
            reason_block(),
            {
                "type": "input",
                "block_id": UNTIL,
                "label": {"type": "plain_text", "text": "Until"},
                "element": {"type": "datetimepicker", "action_id": UNTIL},
            },
        ],
    }


def submitted_values(state):
    values = state.get("values", {})
    ticked = values.get(NOTE, {}).get(NOTE, {}).get("selected_options") or []
    return {
        "reason": (values.get(REASON, {}).get(REASON, {}).get("value") or "").strip(),
        "until": values.get(UNTIL, {}).get(UNTIL, {}).get("selected_date_time"),
        "note": bool(ticked),
        "note_body": values.get(NOTE_TEXT, {}).get(NOTE_TEXT, {}).get("rich_text_value"),
    }


def note_text(values):
    return richtext.flatten(values.get("note_body")) if values.get("note") else ""


def validation_errors(values, needs_until=False):
    if not values.get("reason"):
        return {REASON: "Say why. It goes on the record."}
    if needs_until and not values.get("until"):
        return {UNTIL: "Say when the lock lifts."}
    if values.get("note") and not note_text(values):
        return {NOTE_TEXT: "Write the note or untick it."}
    return None
