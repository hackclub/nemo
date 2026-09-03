CALLBACK = "case_people"
REMOVE = "case_people_remove"

WHO = "people_who"
ROLE = "people_role"
DETAIL = "people_detail"

TITLE_LIMIT = 24

ROLES = (
    ("subject", "Subject"),
    ("involved", "Involved"),
    ("reporter", "Reporter"),
)

ROLE_LABEL = dict(ROLES)


def option(text, value):
    return {"text": {"type": "plain_text", "text": text}, "value": value}


def role_option(role):
    return option(ROLE_LABEL[role], role)


def said_of(one):
    said = f"<@{one['user_id']}> · {ROLE_LABEL.get(one['role'], one['role'])}"
    return f"{said} · {one['detail']}" if one.get("detail") else said


def row(case_id, one):
    return {
        "type": "section",
        "text": {"type": "mrkdwn", "text": said_of(one)[:150]},
        "accessory": {
            "type": "button",
            "action_id": REMOVE,
            "text": {"type": "plain_text", "text": "Remove"},
            "style": "danger",
            "value": f"{one['user_id']}:{one['role']}:{case_id}",
        },
    }


def view(case_id, participants=()):
    blocks = [
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": f"*case {case_id}*"}],
        },
    ]

    if participants:
        blocks += [row(case_id, one) for one in participants]
        blocks.append({"type": "divider"})

    blocks += [
        {
            "type": "input",
            "block_id": WHO,
            "label": {"type": "plain_text", "text": "Add"},
            "element": {
                "type": "multi_users_select",
                "action_id": WHO,
                "placeholder": {"type": "plain_text", "text": "who to add"},
            },
        },
        {
            "type": "input",
            "block_id": ROLE,
            "label": {"type": "plain_text", "text": "Their part in it"},
            "element": {
                "type": "static_select",
                "action_id": ROLE,
                "options": [role_option(role) for role, _ in ROLES],
                "initial_option": role_option("involved"),
            },
        },
        {
            "type": "input",
            "block_id": DETAIL,
            "optional": True,
            "label": {"type": "plain_text", "text": "How they were involved"},
            "element": {
                "type": "plain_text_input",
                "action_id": DETAIL,
                "placeholder": {"type": "plain_text", "text": "it was aimed at them"},
            },
        },
    ]

    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": f"People · case {case_id}"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Add"},
        "close": {"type": "plain_text", "text": "Close"},
        "blocks": blocks,
    }


def picked(state):
    values = state.get("values", {})
    role = (values.get(ROLE, {}).get(ROLE, {}).get("selected_option") or {}).get("value")
    detail = (values.get(DETAIL, {}).get(DETAIL, {}).get("value") or "").strip()
    return {
        "user_ids": values.get(WHO, {}).get(WHO, {}).get("selected_users") or [],
        "role": role,
        "detail": detail if role == "involved" else None,
    }


def removed(value):
    user_id, role, case_id = (value or "").split(":", 2)
    return user_id, role, int(case_id) if case_id.isdigit() else None


def objection(said):
    if not said.get("user_ids"):
        return {WHO: "Say who to add."}
    if said["role"] not in ROLE_LABEL:
        return {ROLE: "Pick their part in it."}
    return None


def role_word(role):
    return "involved" if role == "involved" else f"the {role}"


def added_notice(role, added, already):
    if not added:
        return "everybody you picked was already on this case, nothing changed"

    who = ", ".join(f"<@{one}>" for one in added)
    note = {
        "subject": f"the case is now also about {who}",
        "reporter": f"{who} recorded as reporting it",
    }.get(role, f"{who} added as {role_word(role)}")
    return f"{note}, {len(already)} already there" if already else note
