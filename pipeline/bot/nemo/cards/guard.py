import json

DESTROY_CALLBACK = "thread_destroy"
LOCK_CALLBACK = "thread_lock"

REASON = "guard_reason"
UNTIL = "guard_until"

REASON_LIMIT = 500
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


def reason_block():
    return {
        "type": "input",
        "block_id": REASON,
        "label": {"type": "plain_text", "text": "Why"},
        "element": {
            "type": "plain_text_input",
            "action_id": REASON,
            "multiline": True,
            "max_length": REASON_LIMIT,
        },
    }


def told(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}}


def aside():
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": ASIDE}]}


def destroy_view(channel_id, thread_ts):
    return {
        "type": "modal",
        "callback_id": DESTROY_CALLBACK,
        "private_metadata": metadata(channel_id, thread_ts),
        "title": {"type": "plain_text", "text": "Destroy thread"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Destroy it"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": [told(DESTROY_WARNING), aside(), reason_block()],
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
    return {
        "reason": (values.get(REASON, {}).get(REASON, {}).get("value") or "").strip(),
        "until": values.get(UNTIL, {}).get(UNTIL, {}).get("selected_date_time"),
    }


def objection(said, needs_until=False):
    if not said.get("reason"):
        return {REASON: "Say why. It goes on the record."}
    if needs_until and not said.get("until"):
        return {UNTIL: "Say when the lock lifts."}
    return None
