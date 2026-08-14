SECTION_LIMIT = 3000
CONTEXT_ELEMENTS = 10
QUOTE_LIMIT = 2400
CUT = "\n> [truncated, the whole thing is on the case page]"


def escape(text):
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def quote(body):
    text = escape(body).strip()
    if not text:
        return "> _they sent no words, only what is attached_"
    if len(text) > QUOTE_LIMIT:
        text = text[:QUOTE_LIMIT].rstrip() + CUT
    return "\n".join(f"> {line}" if line else ">" for line in text.splitlines())


def section(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text[:SECTION_LIMIT]}}


def context(parts):
    kept = [part for part in parts if part][:CONTEXT_ELEMENTS]
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": part} for part in kept]}


def heading(case_id, url, category):
    name = f"*<{url}|Case {case_id}>*" if url else f"*Case {case_id}*"
    return section(f"{name} · {category or 'no category yet'}")


def who(is_anonymous, reporter_user_id):
    if is_anonymous or not reporter_user_id:
        return "anonymous"
    return f"from <@{reporter_user_id}>"


def evidence(shares):
    lines = []
    for share in shares[:CONTEXT_ELEMENTS]:
        where = share.get("source_channel_name")
        label = f"#{where}" if where else "a message"
        link = share.get("permalink")
        lines.append(f"• <{link}|{label}>" if link else f"• {label}")
    return lines


def named(files):
    out = []
    for item in files:
        name = escape(item.get("name") or item.get("slack_file_id"))
        if item.get("fetch_state") == "skipped" and item.get("external_url"):
            out.append(f"{name} (lives outside Slack)")
        elif item.get("fetch_state") == "gone":
            out.append(f"{name} (Slack no longer has it)")
        else:
            out.append(name)
    return out


def blocks(case):
    files = case.get("files") or []
    shares = case.get("shares") or []

    built = [
        heading(case["case_id"], case.get("url"), case.get("category_key")),
        section(quote(case.get("body"))),
    ]

    if shares:
        built.append(section("*They pointed at*\n" + "\n".join(evidence(shares))))

    if files:
        built.append(context([f"📎 {name}" for name in named(files)]))

    built.append(
        context(
            [
                who(case.get("is_anonymous", True), case.get("reporter_user_id")),
                f"{len(files)} file" + ("s" if len(files) != 1 else ""),
                "reply in thread and it reaches them",
            ]
        )
    )
    return built


def fallback(case):
    return f"Case {case['case_id']}: a report came in"
