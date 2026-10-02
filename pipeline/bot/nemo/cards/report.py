import re

import yaml

from bot.core import richtext
from bot.core.wording import (
    escape,
    said,
)
from bot.nemo.cards import edit
from lib.paths import CATEGORIES_FILE

MENTION = re.compile(r"(<[@#][A-Z0-9][A-Z0-9]*(?:\|[^>]*)?>)")
SLACK_BIT = re.compile(
    r"(<[@#][A-Z0-9][A-Z0-9]*(?:\|[^>]*)?>|<https?://[^\s<>]+?(?:\|[^>]*)?>)"
)

SECTION_LIMIT = 3000
CONTEXT_ELEMENTS = 10
HEADER_LIMIT = 150

CLAIM = "case_claim"
LOG_ACTION = "case_log_action"
RESOLVE = "case_resolve_open"
REOPEN = "case_reopen"

LABELS = None


def category_label(key):
    global LABELS
    if LABELS is None:
        LABELS = yaml.safe_load(CATEGORIES_FILE.read_text())["categories"]
    if not key:
        return None
    return LABELS.get(key, key.replace("_", " "))


def escape_but_slack(text):
    return "".join(
        part if SLACK_BIT.fullmatch(part) else escape(part)
        for part in SLACK_BIT.split(text or "")
    )


def escape_but_mentions(text):
    return escape_but_slack(text)


def quote(body):
    words = said(body)
    return richtext.quote(words) if words else None


def section(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text[:SECTION_LIMIT]}}


def context(parts):
    kept = [part for part in parts if part][:CONTEXT_ELEMENTS]
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": part} for part in kept]}


def where(case):
    for share in case.get("shares") or []:
        named = share.get("source_channel_name")
        if named:
            return f"#{named}"
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
        return None
    return "about " + ", ".join(f"<@{user_id}>" for user_id in subjects)


def link(case):
    url = case.get("url")
    return f"<{url}|open in fire engine>" if url else None


def reporter(case):
    if case.get("is_anonymous", True) or not case.get("reporter_user_id"):
        return "Anonymous"
    return f"<@{case['reporter_user_id']}>"


def reported(case):
    if case.get("is_anonymous", True) or not case.get("reporter_user_id"):
        return "reported anonymously"
    return f"{reporter(case)} reported it"


def who_and_what(case):
    parts = [reported(case), subjects_line(case), priors(case)]
    return context([" · ".join(part for part in parts if part)])


def footer(case):
    parts = [standing(case), link(case)]
    return context([" · ".join(part for part in parts if part)])


def evidence(shares):
    shown = brought(shares)
    lines = []
    for share in shares[:CONTEXT_ELEMENTS]:
        if any(share is one for one in shown):
            continue
        named = share.get("source_channel_name")
        permalink = share.get("permalink")
        if named:
            said = f"<{permalink}|#{named}>" if permalink else f"#{named}"
        elif room(share):
            said = room(share)
            if permalink:
                said += f" · <{permalink}|open it>"
        else:
            said = f"<{permalink}|a linked message>" if permalink else "a linked message"
        if not share.get("is_reachable"):
            said += " (a link, not shared)"
        lines.append(said)
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


REOPEN_CONFIRM = {
    "title": {"type": "plain_text", "text": "Reopen it?"},
    "text": {
        "type": "mrkdwn",
        "text": "This drops the resolution and takes everybody off it. "
        "The case comes back unclaimed.",
    },
    "confirm": {"type": "plain_text", "text": "Reopen"},
    "deny": {"type": "plain_text", "text": "Leave it closed"},
}


def buttons(case):
    case_id = case["case_id"]

    if case.get("resolved_at"):
        back = button(REOPEN, "Reopen", case_id)
        back["confirm"] = REOPEN_CONFIRM
        return {"type": "actions", "block_id": f"case_{case_id}", "elements": [back]}

    held = case.get("assignees") or []
    elements = []
    if not held:
        elements.append(button(CLAIM, "Claim it", case_id, "primary"))
    elements.append(button(LOG_ACTION, "Log an action", case_id))
    elements.append(button(RESOLVE, "Resolve", case_id, "danger"))

    more = edit.menu(case)
    if more:
        elements.append(more)

    return {"type": "actions", "block_id": f"case_{case_id}", "elements": elements}


def attached(case):
    held = case.get("threads") or 0
    if not held:
        return None

    return f"*{held} thread" + ("s attached*" if held != 1 else " attached*")


SHOWN_SHARES = 3


def brought(shares):
    return [
        share
        for share in shares
        if share.get("is_reachable") and (share.get("source_body") or "").strip()
    ][:SHOWN_SHARES]


def room(share):
    held = share.get("source_channel_id")
    if held:
        return f"<#{held}>"
    named = share.get("source_channel_name")
    return f"#{named}" if named else None


def whose(share):
    who = share.get("source_author_user_id")
    where = room(share)
    said = f"<@{who}>" if who else "somebody"
    if where:
        said += f" in {where}"
    permalink = share.get("permalink")
    return f"{said} · <{permalink}|open it>" if permalink else said


def what_they_reported(case):
    built = []
    for share in brought(case.get("shares") or []):
        built.append(context([whose(share)]))
        words = quote(share["source_body"])
        if words:
            built.append(words)
    return built


def blocks(case):
    files = case.get("files") or []
    shares = case.get("shares") or []

    built = [part for part in [title(case), who_and_what(case), quote(case.get("body"))] if part]
    built += what_they_reported(case)
    built.append(footer(case))

    trail = [part for part in [attached(case)] if part]
    trail += evidence(shares) + [f"📎 {name}" for name in named(files)]
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
