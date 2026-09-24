ANONYMOUS = "anonymous"
NAMED = "named"
ANONYMOUSLY = "anonymously"

BLOCK = "intake_identity"
ACTION = "intake_name"
CONFIRM = "intake_confirm"
CANCEL = "intake_cancel"

SUBTYPE = "consent"
DONE = "consent_done"

FALLBACK = "Submit this report to FD"


READY = (
    "Ready to send this report to FD with your username. Check the box below "
    "to send it anonymously."
)

IDENTITY_OPTION = {
    "text": {"type": "plain_text", "text": "Send it anonymously"},
    "description": {
        "type": "plain_text",
        "text": "FD will not see who filed this report. Leave unchecked to send it "
                "with your username.",
    },
    "value": ANONYMOUSLY,
}


def forwarded(channels):
    if not channels:
        return None

    counted = f"{len(channels)} forwarded message" + ("s" if len(channels) != 1 else "")
    named = [f"#{one}" for one in channels if one]
    if not named:
        return counted

    where = ", ".join(dict.fromkeys(named))
    return f"{counted}, from {where}"


def blocks(bodies=None, files=0, channels=(), held=None):
    built = [{"type": "section", "text": {"type": "mrkdwn", "text": READY}}]

    coming = []
    brought = forwarded(list(channels))
    if brought:
        coming.append(f"↪️ {brought}")
    if files:
        plural = "s" if files != 1 else ""
        coming.append(f"📎 {files} file{plural}")

    if coming:
        built.append(
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": "  ·  ".join(coming)}],
            }
        )

    ticked = {
        "type": "checkboxes",
        "action_id": ACTION,
        "options": [IDENTITY_OPTION],
    }
    if held == ANONYMOUS:
        ticked["initial_options"] = [IDENTITY_OPTION]

    built += [
        {"type": "actions", "block_id": BLOCK, "elements": [ticked]},
        {
            "type": "actions",
            "block_id": "intake_send",
            "elements": [
                {
                    "type": "button",
                    "action_id": CONFIRM,
                    "style": "primary",
                    "text": {"type": "plain_text", "text": "Submit"},
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
    return built


def picked(state):
    held = (state or {}).get("values", {}).get(BLOCK, {})
    if ACTION not in held:
        return None

    ticked = held[ACTION].get("selected_options") or []
    return ANONYMOUS if any(one.get("value") == ANONYMOUSLY for one in ticked) else NAMED


def chosen(state, held=None):
    return picked(state) or held or NAMED


DROPPED = "Nothing was sent. Say more here whenever you want, and I will ask again."
ALREADY = "This one is already with the Fire Department."
