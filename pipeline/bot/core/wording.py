import re

LINK = re.compile(r"(<https?://[^\s<>]+?(?:\|[^>]*)?>)")

QUOTE_LIMIT = 2400
CUT = "\n[truncated, the whole thing is on the case page]"


def escape(text):
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def escape_but_links(text):
    return "".join(
        part if LINK.fullmatch(part) else escape(part)
        for part in LINK.split(text or "")
    )


def said(body):
    text = (body or "").strip()
    if not text:
        return ""
    if len(text) > QUOTE_LIMIT:
        text = text[:QUOTE_LIMIT].rstrip() + CUT
    return text


def to_member(body):
    return escape_but_links(said(body))
