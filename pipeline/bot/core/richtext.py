import html
import re

LEADING_USER_ID = re.compile(r"\A([UW](?=[A-Z0-9]*\d)[A-Z0-9]{6,})(?=\s|\Z)")

PIECE = re.compile(
    r"<@([UW][A-Z0-9]+)(?:\|[^>]*)?>"
    r"|<#(C[A-Z0-9]+)(?:\|[^>]*)?>"
    r"|<(https?://[^|>\s]+)(?:\|([^>]*))?>"
    r"|(?<![<|])(https?://[^\s<>]+)"
)


def leading_user_id(text):
    body = (text or "").lstrip()
    match = LEADING_USER_ID.match(body)
    if not match:
        return None, text
    return match.group(1), body[match.end():].strip()


def link(url, label=None):
    href = html.unescape(url)
    element = {"type": "link", "url": href}
    text = html.unescape(label or "")
    if text and text != href:
        element["text"] = text
    return element


def elements(text, style=None):
    body = text or ""
    out = []
    position = 0

    for match in PIECE.finditer(body):
        preceding_text = body[position : match.start()]
        if preceding_text:
            out.append(text_element(html.unescape(preceding_text), style))

        user_id, channel_id, url, label, bare = match.groups()
        if user_id:
            out.append({"type": "user", "user_id": user_id})
        elif channel_id:
            out.append({"type": "channel", "channel_id": channel_id})
        elif url:
            out.append(link(url, label))
        else:
            out.append(link(bare))
        position = match.end()

    tail = body[position:]
    if tail or not out:
        out.append(text_element(html.unescape(tail), style))
    return out


def text_element(text, style=None):
    element = {"type": "text", "text": text}
    if style:
        element["style"] = style
    return element


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


SECTION = "rich_text_section"
LIST = "rich_text_list"
QUOTE = "rich_text_quote"
PREFORMATTED = "rich_text_preformatted"

BULLET = "• "


def list_runs(part):
    runs = []
    indent = "    " * (part.get("indent") or 0)
    ordered = part.get("style") == "ordered"
    for number, item in enumerate(part.get("elements") or [], start=(part.get("offset") or 0) + 1):
        runs.append(text_element(indent + (f"{number}. " if ordered else BULLET)))
        runs.extend(item.get("elements") or [])
        runs.append(text_element("\n"))
    return runs


def preformatted_runs(part):
    return [
        {**run, "style": {**(run.get("style") or {}), "code": True}} if run.get("type") == "text" else run
        for run in part.get("elements") or []
    ]


def part_runs(part):
    kind = part.get("type")
    if kind == LIST:
        return list_runs(part)
    if kind == PREFORMATTED:
        return preformatted_runs(part)
    if kind in (SECTION, QUOTE):
        return list(part.get("elements") or [])
    return None


def ends_with_newline(runs):
    last = runs[-1] if runs else {}
    return last.get("type") == "text" and (last.get("text") or "").endswith("\n")


def quote_blocks(blocks):
    runs = []
    previous_kind = None
    for block in blocks or []:
        if block.get("type") != "rich_text":
            return None
        for part in block.get("elements") or []:
            kind = part.get("type")
            added = part_runs(part)
            if added is None:
                return None
            both_sections = kind == SECTION and previous_kind == SECTION
            if runs and not both_sections and not ends_with_newline(runs):
                runs.append(text_element("\n"))
            runs.extend(added)
            previous_kind = kind

    if not runs:
        return None
    return {"type": "rich_text", "elements": [{"type": "rich_text_quote", "elements": runs}]}
