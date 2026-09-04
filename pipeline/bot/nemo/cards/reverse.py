from bot.nemo.cards import action

CALLBACK = "case_action_reverse"

WHICH = "reverse_which"
REASON = "reverse_reason"

REASON_LIMIT = 500
TITLE_LIMIT = 24
NO_LABEL = " "


def said_of(one):
    ends = f", until {one['expires_at']:%-d %b}" if one.get("expires_at") else ""
    return f"{action.label(one['type_key'])} on <@{one['target_user_id']}>{ends}"


def option(one):
    return {
        "text": {"type": "plain_text", "text": said_of(one)[:75]},
        "value": str(one["id"]),
    }


def view(case_id, live):
    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": f"Reverse · case {case_id}"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Reverse it"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": [
            {
                "type": "input",
                "block_id": WHICH,
                "label": {"type": "plain_text", "text": "Which action"},
                "element": {
                    "type": "static_select",
                    "action_id": WHICH,
                    "placeholder": {"type": "plain_text", "text": "pick one"},
                    "options": [option(one) for one in live],
                },
            },
            {
                "type": "input",
                "block_id": REASON,
                "label": {"type": "plain_text", "text": "Why it is being reversed"},
                "element": {
                    "type": "plain_text_input",
                    "action_id": REASON,
                    "multiline": True,
                    "max_length": REASON_LIMIT,
                },
            },
        ],
    }


def picked(state):
    values = state.get("values", {})
    which = (values.get(WHICH, {}).get(WHICH, {}).get("selected_option") or {}).get("value")
    return {
        "action_id": int(which) if which else None,
        "reason": (values.get(REASON, {}).get(REASON, {}).get("value") or "").strip(),
    }


def objection(said):
    if not said.get("action_id"):
        return {WHICH: "Pick the action to reverse."}
    if not said.get("reason"):
        return {REASON: "Say why it is being reversed. It goes on the record."}
    return None
