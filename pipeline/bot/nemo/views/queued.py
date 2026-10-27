from bot.nemo.views import linked, report


def body(case):
    return linked.plain(
        linked.numbered_quote(report.quote(case.get("body")), case.get("numbering"))
    )


def build_blocks(case):
    body_block = body(case)
    return [body_block] if body_block else report.header_blocks(case)


def needs_header(case):
    return body(case) is not None


def fallback(case):
    return report.headline(case)


def metadata(case):
    payload = {"case_id": case["case_id"], "report_id": None}
    if case.get("opening_id") and case.get("opened_by"):
        payload["source_user_id"] = case["opened_by"]
    return {"event_type": "fd_case_card", "event_payload": payload}
