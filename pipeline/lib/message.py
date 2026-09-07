import re

MENTION = re.compile(r"<@([UW][A-Z0-9]+)")
EMOJI_ONLY = re.compile(r"(:[a-z0-9_+'-]+:\s*)+\Z")
SUBSTANTIVE_CHARS = 80

REDACT = (
    "text",
    "blocks",
    "attachments",
    "files",
    "previous_message",
    "profile",
    "user_profile",
    "bot_profile",
    "purpose",
    "topic",
    "comment",
    "permalink",
    "plain_text",
    "rich_text",
    "fallback",
    "pretext",
    "title",
    "title_link",
    "footer",
    "canvas",
    "huddle",
)

USER_KEPT = ("id", "team_id", "is_bot", "is_admin", "deleted", "updated")


def thin_user(value):
    if not isinstance(value, dict):
        return value
    return {k: v for k, v in value.items() if k in USER_KEPT}


def scrub(value):
    if isinstance(value, dict):
        return {
            k: (thin_user(v) if k == "user" else scrub(v))
            for k, v in value.items()
            if k not in REDACT
        }
    if isinstance(value, list):
        return [scrub(v) for v in value]
    return value


def author_kind(message):
    if message.get("bot_id") or message.get("subtype") == "bot_message":
        return "bot"
    if message.get("user"):
        return "member"
    return "unknown"


def derived(text):
    body = text or ""
    stripped = body.strip()
    mentions = MENTION.findall(body)
    return {
        "text_length": len(body),
        "has_text": bool(stripped),
        "mentioned_ids": mentions,
        "mention_count": len(mentions),
        "is_question": "?" in body,
        "is_substantive": len(body) >= SUBSTANTIVE_CHARS,
        "has_link": "http" in body,
        "emoji_only": bool(stripped) and bool(EMOJI_ONLY.fullmatch(stripped)),
    }


def shape(message):
    reactions = message.get("reactions") or []
    counted = derived(message.get("text"))
    counted.update({
        "block_count": len(message.get("blocks") or []),
        "attachment_count": len(message.get("attachments") or []),
        "file_count": len(message.get("files") or []),
        "reaction_count": sum(r.get("count") or 0 for r in reactions),
        "reactor_count": len({u for r in reactions for u in (r.get("users") or [])}),
    })
    return counted
