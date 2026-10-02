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
    said = html.unescape(label or "")
    if said and said != href:
        made["text"] = said
    return made


def elements(text, style=None):
    said = text or ""
    out = []
    at = 0

    for found in PIECE.finditer(said):
        before = said[at : found.start()]
        if before:
            out.append(word(before, style))

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

    rest = said[at:]
    if rest or not out:
        out.append(word(rest, style))
    return out


def word(text, style=None):
    made = {"type": "text", "text": text}
    if style:
        made["style"] = style
    return made


def mentions(text):
    return bool(MENTION.search(text or ""))


def flatten(value):
    if not value:
        return ""

    said = []
    for block in value.get("elements") or []:
        for part in block.get("elements") or []:
            kind = part.get("type")
            if kind == "user":
                said.append(f"<@{part['user_id']}>")
            elif kind == "channel":
                said.append(f"<#{part['channel_id']}>")
            elif kind == "link":
                said.append(part.get("url") or "")
            elif kind == "emoji":
                said.append(f":{part.get('name')}:")
            else:
                said.append(part.get("text") or "")
        said.append("\n")

    return "".join(said).strip()


def quote(text, style=None):
    return {
        "type": "rich_text",
        "elements": [{"type": "rich_text_quote", "elements": elements(text, style)}],
    }
