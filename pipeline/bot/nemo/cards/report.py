SECTION_LIMIT = 3000
CONTEXT_ELEMENTS = 10
QUOTE_LIMIT = 2400
HEADER_LIMIT = 150
CUT = "\n[truncated, the whole thing is on the case page]"

OPEN = "🟥"
HELD = "🟨"
CLOSED = "🟩"


def escape(text):
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def said(body):
    text = (body or "").strip()
    if not text:
        return "they sent no words, only what is attached"
    if len(text) > QUOTE_LIMIT:
        text = text[:QUOTE_LIMIT].rstrip() + CUT
    return text


def quote(body):
    return {
        "type": "rich_text",
        "elements": [
            {"type": "rich_text_quote", "elements": [{"type": "text", "text": said(body)}]}
        ],
    }


def section(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text[:SECTION_LIMIT]}}


def context(parts):
    kept = [part for part in parts if part][:CONTEXT_ELEMENTS]
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": part} for part in kept]}


def title(case):
    name = f"Case {case['case_id']}"
    category = (case.get("category_key") or "").replace("_", " ")
    line = f"{name} · {category}" if category else name
    return {"type": "header", "text": {"type": "plain_text", "text": line[:HEADER_LIMIT]}}


def standing(case):
    held = case.get("assignees") or []
    if case.get("resolved_at"):
        return "*Resolved*"
    if held:
        return ", ".join(f"<@{user_id}>" for user_id in held) + " has it"
    return "*Open*"


def when(case):
    at = case.get("received_at")
    return at.strftime("%-d %b, %H:%M") if at else None


def link(case):
    url = case.get("url")
    return f"<{url}|open in Fire Engine>" if url else None


def reporter(case):
    if case.get("is_anonymous", True) or not case.get("reporter_user_id"):
        return "anonymous"
    return f"from <@{case['reporter_user_id']}>"


def sent(case):
    counted = []
    files = len(case.get("files") or [])
    shares = len(case.get("shares") or [])
    if files:
        counted.append(f"{files} file" + ("s" if files != 1 else ""))
    if shares:
        counted.append(f"{shares} linked message" + ("s" if shares != 1 else ""))
    return ", ".join(counted) or None


def about(case):
    subjects = case.get("subjects") or []
    if not subjects:
        return None
    who = ", ".join(f"<@{user_id}>" for user_id in subjects)
    others = case.get("other_cases") or 0
    if not others:
        return f"about {who}, nothing else on their record"
    return f"about {who}, {others} other case" + ("s" if others != 1 else "")


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


def blocks(case):
    files = case.get("files") or []
    shares = case.get("shares") or []

    line = " · ".join(
        part
        for part in [standing(case), reporter(case), sent(case), when(case), link(case)]
        if part
    )

    built = [title(case), quote(case.get("body")), context([line])]

    held = about(case)
    if held:
        built.append(context([held]))

    trail = evidence(shares) + [f"📎 {name}" for name in named(files)]
    if trail:
        built.append(context([" · ".join(trail)]))

    return built


def fallback(case):
    return f"Case {case['case_id']}: a report came in"


def follow_up(body, file_count=0):
    text = escape(said(body))
    quoted = "\n".join(f"> {line}" if line else ">" for line in text.splitlines())
    if not file_count:
        return quoted
    plural = "s" if file_count != 1 else ""
    return f"{quoted}\n_they also sent {file_count} file{plural}_"


def to_member(body):
    return escape(said(body))
