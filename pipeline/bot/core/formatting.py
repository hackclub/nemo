import datetime as dt
import re

LINK = re.compile(r"(<https?://[^\s<>]+?(?:\|[^>]*)?>)")
MEMBER_TOKEN = re.compile(
    r"(<https?://[^\s<>]+?(?:\|[^>]*)?>|<@[UW][A-Z0-9]+(?:\|[^>]*)?>|<#C[A-Z0-9]+(?:\|[^>]*)?>)"
)

UNESCAPED_AMPERSAND = re.compile(r"&(?!(?:amp|lt|gt);)")

QUOTE_LIMIT = 2400
CUT = "\n[truncated]"
MEMBER_PART_LIMIT = 3000
SPLIT_POINTS = ("\n\n", "\n", " ")


def escape(text):
    return UNESCAPED_AMPERSAND.sub("&amp;", text or "").replace("<", "&lt;").replace(">", "&gt;")


def escape_but_links(text):
    return "".join(
        part if LINK.fullmatch(part) else escape(part)
        for part in LINK.split(text or "")
    )


def escape_but_member_tokens(text):
    return "".join(
        part if MEMBER_TOKEN.fullmatch(part) else escape(part)
        for part in MEMBER_TOKEN.split(text or "")
    )


def quote_text(body, cut=CUT):
    text = (body or "").strip()
    if not text:
        return ""
    if len(text) > QUOTE_LIMIT:
        text = text[:QUOTE_LIMIT].rstrip() + cut
    return text


def split_point(window, limit):
    for separator in SPLIT_POINTS:
        index = window.rfind(separator)
        if index > limit // 2:
            return index
    return limit


def outside_token(window, cut):
    token_start = window.rfind("<", 0, cut)
    if token_start > 0 and token_start > window.rfind(">", 0, cut):
        return token_start
    return cut


def split_text(text, limit=MEMBER_PART_LIMIT):
    parts = []
    remaining = text
    while len(remaining) > limit:
        window = remaining[:limit]
        cut = outside_token(window, split_point(window, limit))
        parts.append(remaining[:cut].rstrip())
        remaining = remaining[cut:].lstrip()
    if remaining:
        parts.append(remaining)
    return parts


def member_parts(body):
    text = (body or "").strip()
    return [escape_but_member_tokens(part) for part in split_text(text)] if text else []


def short_date(value, today=None):
    if value.year == (today or dt.date.today()).year:
        return value.strftime("%-d %b")
    return value.strftime("%-d %b %Y")


def short_end(value, today=None):
    if not isinstance(value, dt.datetime):
        return short_date(value, today)
    utc_value = value.astimezone(dt.timezone.utc) if value.tzinfo else value
    if (utc_value.hour, utc_value.minute) == (23, 59):
        return short_date(utc_value, today)
    return f"{short_date(utc_value, today)}, {utc_value:%H:%M} UTC"


def date_token(value, fallback):
    return f"<!date^{int(value.timestamp())}^{{date_short_pretty}} at {{time}}|{fallback}>"


def short_end_token(value, today=None):
    if not isinstance(value, dt.datetime):
        return short_date(value, today)
    utc_value = value.astimezone(dt.timezone.utc) if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)
    if (utc_value.hour, utc_value.minute) == (23, 59):
        return short_date(utc_value, today)
    return date_token(utc_value, f"{utc_value:%-d %b %Y, %H:%M} UTC")
