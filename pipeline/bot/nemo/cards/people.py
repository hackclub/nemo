CALLBACK = "case_people"
REMOVE = "case_people_remove"

WHO = "people_who"

TITLE_LIMIT = 24

SUBJECT = "subject"

ROLE_LABEL = {"subject": "Subject", "reporter": "Reporter"}


def option(text, value):
    return {"text": {"type": "plain_text", "text": text}, "value": value}


def said_of(one):
    return f"<@{one['user_id']}> · {ROLE_LABEL.get(one['role'], one['role'])}"


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
    blocks = []

    if participants:
        blocks += [row(case_id, one) for one in participants]
        blocks.append({"type": "divider"})

    blocks += [
        {
            "type": "input",
            "block_id": WHO,
            "label": {"type": "plain_text", "text": "Subject"},
            "element": {
                "type": "multi_users_select",
                "action_id": WHO,
                "placeholder": {"type": "plain_text", "text": "who the case is about"},
            },
        },
    ]

    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": f"Subjects · case {case_id}"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Add"},
        "close": {"type": "plain_text", "text": "Close"},
        "blocks": blocks,
    }


def picked(state):
    values = state.get("values", {})
    return {
        "user_ids": values.get(WHO, {}).get(WHO, {}).get("selected_users") or [],
        "role": SUBJECT,
        "detail": None,
    }


def removed(value):
    user_id, role, case_id = (value or "").split(":", 2)
    return user_id, role, int(case_id) if case_id.isdigit() else None


def objection(said):
    if not said.get("user_ids"):
        return {WHO: "Say who the subject is."}
    return None
