import re

MENTION = re.compile(r"<@([UW][A-Z0-9]+)(?:\|[^>]*)?>|<#(C[A-Z0-9]+)(?:\|[^>]*)?>")


def elements(text, style=None):
    said = text or ""
    out = []
    at = 0

    for found in MENTION.finditer(said):
        before = said[at : found.start()]
        if before:
            out.append(word(before, style))
        user_id, channel_id = found.group(1), found.group(2)
        if user_id:
            out.append({"type": "user", "user_id": user_id})
        else:
            out.append({"type": "channel", "channel_id": channel_id})
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
