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


def blocks(bodies, files=0):
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

    if files:
        plural = "s" if files != 1 else ""
        built.append(
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": f"📎 {files} file{plural}"}],
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
                    "initial_option": ANONYMOUS_OPTION,
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


def chosen(state):
    picked = (
        (state or {})
        .get("values", {})
        .get(BLOCK, {})
        .get(ACTION, {})
        .get("selected_option")
    )
    return (picked or {}).get("value") or ANONYMOUS


DROPPED = "Nothing was sent. Say more here whenever you want, and I will ask again."
ALREADY = "This one is already with the Fire Department."
