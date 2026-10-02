from bot.nemo.cards import edit, report

HEADER_LIMIT = 150


def headline(case):
    return f"Case {case['case_id']}"


def title(case):
    return {
        "type": "header",
        "text": {"type": "plain_text", "text": headline(case)[:HEADER_LIMIT]},
    }


def standing(case):
    held = case.get("assignees") or []
    if case.get("resolved_at"):
        return "*Resolved*"
    if held:
        return ", ".join(f"<@{user_id}>" for user_id in held) + " has it"
    return "*Open*"


def about(case):
    subjects = case.get("subjects") or []
    if not subjects:
        return None
    return "about " + ", ".join(f"<@{user_id}>" for user_id in subjects)


def named(case):
    key = case.get("category_key")
    return report.category_label(key) if key else None


def footer(case):
    parts = [standing(case), about(case), named(case), report.link(case)]
    return report.context([" · ".join(one for one in parts if one)])


def buttons(case):
    case_id = case["case_id"]
    if case.get("resolved_at"):
        back = report.button(report.REOPEN, "Reopen", case_id)
        back["confirm"] = report.REOPEN_CONFIRM
        return {"type": "actions", "block_id": f"case_{case_id}", "elements": [back]}

    held = case.get("assignees") or []
    elements = []
    if not held:
        elements.append(report.button(report.CLAIM, "Claim it", case_id, "primary"))
    elements.append(report.button(report.LOG_ACTION, "Log an action", case_id))
    elements.append(report.button(report.RESOLVE, "Resolve", case_id, "danger"))

    more = edit.menu(case)
    if more:
        elements.append(more)

    return {"type": "actions", "block_id": f"case_{case_id}", "elements": elements}


def blocks(case):
    return [title(case), footer(case), buttons(case)]


def fallback(case):
    return f"Case {case['case_id']} · {standing(case).strip('*').lower()}"


def metadata(case):
    return {
        "event_type": "fd_case_card",
        "event_payload": {"case_id": case["case_id"], "report_id": None},
    }
