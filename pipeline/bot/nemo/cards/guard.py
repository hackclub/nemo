import json

from bot.core import richtext

DESTROY_CALLBACK = "thread_destroy"
LOCK_CALLBACK = "thread_lock"

REASON = "guard_reason"
UNTIL = "guard_until"
NOTE = "guard_note"
SAID = "guard_note_said"

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
        said = json.loads(view.get("private_metadata") or "{}")
    except ValueError:
        return None, None
    return said.get("channel_id"), said.get("thread_ts")


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


def said_block(value=None):
    element = {
        "type": "rich_text_input",
        "action_id": SAID,
        "min_lines": 4,
        "placeholder": {"type": "plain_text", "text": "what you did and why"},
    }
    if value:
        element["initial_value"] = value
    return {
        "type": "input",
        "block_id": SAID,
        "label": {"type": "plain_text", "text": "What it says"},
        "element": element,
    }


def told(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}}


def aside():
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": ASIDE}]}


def destroy_view(channel_id, thread_ts, said=None):
    said = said or {}
    blocks = [
        told(DESTROY_WARNING),
        aside(),
        reason_block(said.get("reason")),
        note_block(said.get("note")),
    ]
    if said.get("note"):
        blocks.append(said_block(said.get("note_said")))

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
            told(LOCK_WARNING),
            aside(),
            reason_block(),
            {
                "type": "input",
                "block_id": UNTIL,
                "label": {"type": "plain_text", "text": "Until"},
                "element": {"type": "datetimepicker", "action_id": UNTIL},
            },
        ],
    }


def picked(state):
    values = state.get("values", {})
    ticked = values.get(NOTE, {}).get(NOTE, {}).get("selected_options") or []
    return {
        "reason": (values.get(REASON, {}).get(REASON, {}).get("value") or "").strip(),
        "until": values.get(UNTIL, {}).get(UNTIL, {}).get("selected_date_time"),
        "note": bool(ticked),
        "note_said": values.get(SAID, {}).get(SAID, {}).get("rich_text_value"),
    }


def note_words(said):
    return richtext.flatten(said.get("note_said")) if said.get("note") else ""


def objection(said, needs_until=False):
    if not said.get("reason"):
        return {REASON: "Say why. It goes on the record."}
    if needs_until and not said.get("until"):
        return {UNTIL: "Say when the lock lifts."}
    if said.get("note") and not note_words(said):
        return {SAID: "Write the note or untick it."}
    return None
