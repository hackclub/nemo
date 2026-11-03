import re

from bot.core import richtext
from bot.core.formatting import (
    escape,
    quote_text,
)
from bot.nemo import categories
from bot.nemo.views import case_card, linked, shortcut_report

MENTION = re.compile(r"(<[@#][A-Z0-9][A-Z0-9]*(?:\|[^>]*)?>)")
SLACK_BIT = re.compile(
    r"(<[@#][A-Z0-9][A-Z0-9]*(?:\|[^>]*)?>|<https?://[^\s<>]+?(?:\|[^>]*)?>)"
)


def category_label(key):
    return categories.label(key)


def escape_but_slack(text):
    return "".join(
        part if SLACK_BIT.fullmatch(part) else escape(part)
        for part in SLACK_BIT.split(text or "")
    )


def escape_but_mentions(text):
    return escape_but_slack(text)


def quote(body, blocks=None):
    if blocks:
        quote_value = richtext.quote_blocks(blocks)
        if quote_value:
            return quote_value

    words = quote_text(body)
    return richtext.quote(words) if words else None


def headline(case):
    name = f"Case {case['case_id']}"
    label = category_label(case.get("category_key"))
    return f"{name}: {label}" if label else name


def body(case):
    return linked.plain(
        linked.numbered_quote(quote(case.get("body"), case.get("blocks")), case.get("numbering"))
    )


def header_blocks(case):
    return case_card.blocks(case)


def build_blocks(case):
    if shortcut_report.is_shortcut(case):
        return shortcut_report.blocks(case) or header_blocks(case)
    body_block = body(case)
    return [body_block] if body_block else header_blocks(case)


def needs_header(case):
    if shortcut_report.is_shortcut(case):
        return bool(shortcut_report.blocks(case))
    return body(case) is not None


def fallback(case):
    return headline(case)


def metadata(case):
    payload = {"case_id": case["case_id"], "report_id": case.get("report_id")}
    if case.get("reporter_user_id") and not case.get("is_anonymous"):
        payload["source_user_id"] = case["reporter_user_id"]
    return {"event_type": "fd_case_card", "event_payload": payload}
