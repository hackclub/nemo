import re

import yaml

from bot.engine import richtext
from lib.paths import CATEGORIES_FILE

MENTION = re.compile(r"(<[@#][A-Z0-9][A-Z0-9]*(?:\|[^>]*)?>)")

SECTION_LIMIT = 3000
CONTEXT_ELEMENTS = 10
QUOTE_LIMIT = 2400
HEADER_LIMIT = 150
CUT = "\n[truncated, the whole thing is on the case page]"

CLAIM = "case_claim"
LOG_ACTION = "case_log_action"

LABELS = None


def category_label(key):
    global LABELS
    if LABELS is None:
        LABELS = yaml.safe_load(CATEGORIES_FILE.read_text())["categories"]
    if not key:
        return None
    return LABELS.get(key, key.replace("_", " "))


def escape(text):
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def escape_but_mentions(text):
    return "".join(
        part if MENTION.fullmatch(part) else escape(part)
        for part in MENTION.split(text or "")
    )


def said(body):
    text = (body or "").strip()
    if not text:
        return "they sent no words, only what is attached"
    if len(text) > QUOTE_LIMIT:
        text = text[:QUOTE_LIMIT].rstrip() + CUT
    return text


def quote(body):
    return richtext.quote(said(body))


def section(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text[:SECTION_LIMIT]}}


def context(parts):
    kept = [part for part in parts if part][:CONTEXT_ELEMENTS]
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": part} for part in kept]}


def where(case):
    for share in case.get("shares") or []:
        if share.get("source_channel_name"):
            return f"#{share['source_channel_name']}"
    return None


def what_it_is(case):
    label = category_label(case.get("category_key"))
    channel = where(case)
    if label and channel:
        return f"{label} in {channel}"
    if label:
        return label
    if channel:
        return f"a report about {channel}"
    return None


def headline(case):
    name = f"Case {case['case_id']}"
    what = what_it_is(case)
    return f"{name} · {what}" if what else name


def title(case):
    return {
        "type": "header",
        "text": {"type": "plain_text", "text": headline(case)[:HEADER_LIMIT]},
    }


def standing(case):
    held = case.get("assignees") or []
    if case.get("resolved_at"):
        return "*Resolved*"
    if held:
        return ", ".join(f"<@{user_id}>" for user_id in held) + " has it"
    return "*Open*"


def priors(case):
    others = case.get("other_cases") or 0
    if not others or not case.get("subjects"):
        return None
    return f":warning: *{others} other case" + ("s*" if others != 1 else "*")


def subjects_line(case):
    subjects = case.get("subjects") or []
    if not subjects:
        return "nobody named yet"
    return "about " + ", ".join(f"<@{user_id}>" for user_id in subjects)


def link(case):
    url = case.get("url")
    return f"<{url}|open in fire engine>" if url else None


def reporter(case):
    if case.get("is_anonymous", True) or not case.get("reporter_user_id"):
        return "anonymous"
    return f"<@{case['reporter_user_id']}>"


def reported(case):
    if case.get("is_anonymous", True) or not case.get("reporter_user_id"):
        return "reported anonymously"
    return f"{reporter(case)} reported it"


def footer(case):
    parts = [
        standing(case),
        subjects_line(case),
        priors(case),
        reported(case),
        link(case),
    ]
    return context([" · ".join(part for part in parts if part)])


def evidence(shares):
    lines = []
    for share in shares[:CONTEXT_ELEMENTS]:
        where = share.get("source_channel_name")
        label = f"#{where}" if where else "a linked message"
        permalink = share.get("permalink")
        lines.append(f"<{permalink}|{label}>" if permalink else label)
    return lines


SAID = {
    "stored": "kept",
    "pending": "not kept yet",
    "skipped": "lives outside Slack",
    "gone": "Slack no longer has it",
    "too_large": "too big to keep",
    "refused": "Slack would not hand it over",
    "failed": "we could not keep it",
}


def named(files):
    out = []
    for item in files:
        name = escape(item.get("name") or item.get("slack_file_id"))
        note = SAID.get(item.get("fetch_state"))
        out.append(f"{name} ({note})" if note else name)
    return out


def button(action_id, label, case_id, style=None):
    made = {
        "type": "button",
        "action_id": action_id,
        "text": {"type": "plain_text", "text": label},
        "value": str(case_id),
    }
    if style:
        made["style"] = style
    return made


def buttons(case):
    if case.get("resolved_at"):
        return None

    case_id = case["case_id"]
    elements = []
    if not case.get("assignees"):
        elements.append(button(CLAIM, "Claim it", case_id, "primary"))
    elements.append(button(LOG_ACTION, "Log an action", case_id))

    return {"type": "actions", "block_id": f"case_{case_id}", "elements": elements}


def blocks(case):
    files = case.get("files") or []
    shares = case.get("shares") or []

    built = [title(case), quote(case.get("body")), footer(case)]

    trail = evidence(shares) + [f"📎 {name}" for name in named(files)]
    if trail:
        built.append(context([" · ".join(trail)]))

    acting = buttons(case)
    if acting:
        built.append(acting)

    return built


def fallback(case):
    return f"Case {case['case_id']}: {headline(case).lower()}"


def metadata(case):
    return {
        "event_type": "fd_case_card",
        "event_payload": {"case_id": case["case_id"], "report_id": case.get("report_id")},
    }


def to_member(body):
    return escape(said(body))
