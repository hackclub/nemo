from bot.engine import richtext

QUOTE_LIMIT = 2000
CUT = "\n> [there is more, and they will see all of it]"

ANONYMOUS = "anonymous"
NAMED = "named"

BLOCK = "intake_identity"
ACTION = "intake_name"
CONFIRM = "intake_confirm"
CANCEL = "intake_cancel"

SUBTYPE = "consent"
DONE = "consent_done"

FALLBACK = "Send this to the Fire Department?"


def escape(text):
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def quote(bodies):
    said = "\n\n".join(body.strip() for body in bodies if (body or "").strip())
    if not said:
        return None
    if len(said) > QUOTE_LIMIT:
        said = said[:QUOTE_LIMIT].rstrip() + CUT
    return said


def quoted(bodies):
    said = quote(bodies)
    if said is None:
        return richtext.quote("no words yet, only what you attached", {"italic": True})
    return richtext.quote(said)


def option(value, label, note):
    return {
        "text": {"type": "mrkdwn", "text": f"*{label}*"},
        "description": {"type": "mrkdwn", "text": note},
        "value": value,
    }


ANONYMOUS_OPTION = option(
    ANONYMOUS,
    "Send it anonymously",
    "They see _a member_. Only the bot knows it was you.",
)

NAMED_OPTION = option(
    NAMED,
    "Sign it with my name",
    "They see your handle, and can thank you properly.",
)


def forwarded(channels):
    if not channels:
        return None

    counted = f"{len(channels)} forwarded message" + ("s" if len(channels) != 1 else "")
    named = [f"#{one}" for one in channels if one]
    if not named:
        return counted

    where = ", ".join(dict.fromkeys(named))
    return f"{counted}, from {where}"


def blocks(bodies, files=0, channels=(), held=None):
    built = [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*Ready when you are.* The Fire Department will see this:",
            },
        },
        quoted(bodies),
    ]

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

    built += [
        {
            "type": "actions",
            "block_id": BLOCK,
            "elements": [
                {
                    "type": "radio_buttons",
                    "action_id": ACTION,
                    "initial_option": NAMED_OPTION if held == NAMED else ANONYMOUS_OPTION,
                    "options": [ANONYMOUS_OPTION, NAMED_OPTION],
                }
            ],
        },
        {
            "type": "actions",
            "block_id": "intake_send",
            "elements": [
                {
                    "type": "button",
                    "action_id": CONFIRM,
                    "style": "primary",
                    "text": {"type": "plain_text", "text": "Send to FD"},
                },
                {
                    "type": "button",
                    "action_id": CANCEL,
                    "text": {"type": "plain_text", "text": "Not yet"},
                },
            ],
        },
    ]
    return built


def picked(state):
    found = (
        (state or {})
        .get("values", {})
        .get(BLOCK, {})
        .get(ACTION, {})
        .get("selected_option")
    )
    return (found or {}).get("value")


def chosen(state, held=None):
    return picked(state) or held or ANONYMOUS


DROPPED = "Nothing was sent. Say more here whenever you want, and I will ask again."
ALREADY = "This one is already with the Fire Department."
