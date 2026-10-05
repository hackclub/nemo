import html
import re

MENTION = re.compile(r"<@([UW][A-Z0-9]+)(?:\|[^>]*)?>|<#(C[A-Z0-9]+)(?:\|[^>]*)?>")

PIECE = re.compile(
    r"<@([UW][A-Z0-9]+)(?:\|[^>]*)?>"
    r"|<#(C[A-Z0-9]+)(?:\|[^>]*)?>"
    r"|<(https?://[^|>\s]+)(?:\|([^>]*))?>"
    r"|(?<![<|])(https?://[^\s<>]+)"
)


def link(url, label=None):
    href = html.unescape(url)
    made = {"type": "link", "url": href}
    text = html.unescape(label or "")
    if text and text != href:
        made["text"] = text
    return made


def elements(text, style=None):
    body = text or ""
    out = []
    at = 0

    for found in PIECE.finditer(body):
        before = body[at : found.start()]
        if before:
            out.append(text_element(before, style))

        user_id, channel_id, url, label, bare = found.groups()
        if user_id:
            out.append({"type": "user", "user_id": user_id})
        elif channel_id:
            out.append({"type": "channel", "channel_id": channel_id})
        elif url:
            out.append(link(url, label))
        else:
            out.append(link(bare))
        at = found.end()

    rest = body[at:]
    if rest or not out:
        out.append(text_element(rest, style))
    return out


def text_element(text, style=None):
    made = {"type": "text", "text": text}
    if style:
        made["style"] = style
    return made


def mentions(text):
    return bool(MENTION.search(text or ""))


def flatten(value):
    if not value:
        return ""

    parts = []
    for block in value.get("elements") or []:
        for part in block.get("elements") or []:
            kind = part.get("type")
            if kind == "user":
                parts.append(f"<@{part['user_id']}>")
            elif kind == "channel":
                parts.append(f"<#{part['channel_id']}>")
            elif kind == "link":
                parts.append(part.get("url") or "")
            elif kind == "emoji":
                parts.append(f":{part.get('name')}:")
            else:
                parts.append(part.get("text") or "")
        parts.append("\n")

    return "".join(parts).strip()


def quote(text, style=None):
    return {
        "type": "rich_text",
        "elements": [{"type": "rich_text_quote", "elements": elements(text, style)}],
    }


def quote_blocks(blocks):
    runs = []
    for block in blocks or []:
        if block.get("type") != "rich_text":
            return None
        for part in block.get("elements") or []:
            if part.get("type") != "rich_text_section":
                return None
            runs.extend(part.get("elements") or [])

    if not runs:
        return None
    return {"type": "rich_text", "elements": [{"type": "rich_text_quote", "elements": runs}]}
