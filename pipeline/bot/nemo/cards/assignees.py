CALLBACK = "case_assignees"
REMOVE = "case_assignees_remove"

WHO = "assignees_who"

TITLE_LIMIT = 24


def row(case_id, user_id):
    return {
        "type": "section",
        "text": {"type": "mrkdwn", "text": f"<@{user_id}>"},
        "accessory": {
            "type": "button",
            "action_id": REMOVE,
            "text": {"type": "plain_text", "text": "Take off it"},
            "style": "danger",
            "value": f"{user_id}:{case_id}",
        },
    }


def view(case_id, held=()):
    blocks = []

    if held:
        blocks += [row(case_id, user_id) for user_id in held]
        blocks.append({"type": "divider"})

    blocks.append(
        {
            "type": "input",
            "block_id": WHO,
            "label": {"type": "plain_text", "text": "Assign"},
            "element": {
                "type": "multi_users_select",
                "action_id": WHO,
                "placeholder": {"type": "plain_text", "text": "who to put on it"},
            },
        }
    )

    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": f"Assignees · case {case_id}"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Assign"},
        "close": {"type": "plain_text", "text": "Close"},
        "blocks": blocks,
    }


def removed(value):
    user_id, _, case_id = (value or "").rpartition(":")
    return user_id, int(case_id) if case_id.isdigit() else None


def picked(state):
    values = state.get("values", {})
    return {
        "user_ids": values.get(WHO, {}).get(WHO, {}).get("selected_users") or [],
    }


def objection(said):
    if not said.get("user_ids"):
        return {WHO: "Say who to assign."}
    return None
