ANONYMOUS = "anonymous"
NAMED = "named"
WITH_USERNAME = "with_username"

BLOCK = "intake_identity"
ACTION = "intake_name"
CONFIRM = "intake_confirm"
CANCEL = "intake_cancel"

SUBTYPE = "consent"
DONE = "consent_done"

FALLBACK = "Send this report to the Fire Department?"


IDENTITY_OPTION = {
    "text": {"type": "plain_text", "text": "Include my username"},
    "description": {
        "type": "plain_text",
        "text": "FD will see who filed this report. Leave unchecked to stay anonymous.",
    },
    "value": WITH_USERNAME,
}


def forwarded(channels):
    if not channels:
        return None

    count_text = f"{len(channels)} forwarded message" + ("s" if len(channels) != 1 else "")
    channel_names = [f"#{one}" for one in channels if one]
    if not channel_names:
        return count_text

    source_channels = ", ".join(dict.fromkeys(channel_names))
    return f"{count_text}, from {source_channels}"


def build_blocks(bodies=None, files=0, channels=(), saved_choice=None):
    blocks = [{"type": "section", "text": {"type": "mrkdwn", "text": FALLBACK}}]

    summary_parts = []
    forwarded_summary = forwarded(list(channels))
    if forwarded_summary:
        summary_parts.append(forwarded_summary)
    if files:
        plural = "s" if files != 1 else ""
        summary_parts.append(f"{files} file{plural}")

    if summary_parts:
        blocks.append(
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": ", ".join(summary_parts)}],
            }
        )

    identity_checkbox = {
        "type": "checkboxes",
        "action_id": ACTION,
        "options": [IDENTITY_OPTION],
    }
    if saved_choice == NAMED:
        identity_checkbox["initial_options"] = [IDENTITY_OPTION]

    blocks += [
        {"type": "actions", "block_id": BLOCK, "elements": [identity_checkbox]},
        {
            "type": "actions",
            "block_id": "intake_send",
            "elements": [
                {
                    "type": "button",
                    "action_id": CONFIRM,
                    "style": "primary",
                    "text": {"type": "plain_text", "text": "Send"},
                },
                {
                    "type": "button",
                    "action_id": CANCEL,
                    "style": "danger",
                    "text": {"type": "plain_text", "text": "Cancel"},
                },
            ],
        },
    ]
    return blocks


def submitted_values(state):
    block_values = (state or {}).get("values", {}).get(BLOCK, {})
    if ACTION not in block_values:
        return None

    checked_options = block_values[ACTION].get("selected_options") or []
    return NAMED if any(one.get("value") == WITH_USERNAME for one in checked_options) else ANONYMOUS


def resolve_choice(state, saved_choice=None):
    return submitted_values(state) or saved_choice or ANONYMOUS


CANCELLED = "Cancelled"
ALREADY_SENT = "Already sent"
