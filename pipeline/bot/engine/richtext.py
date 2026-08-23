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


def quote(text, style=None):
    return {
        "type": "rich_text",
        "elements": [{"type": "rich_text_quote", "elements": elements(text, style)}],
    }
