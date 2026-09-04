import yaml

from bot.nemo.cards import edit
from lib.paths import ACTIONS_FILE

CALLBACK = "case_action_log"

TARGET = "action_target"
KIND = "action_kind"
UNTIL = "action_until"
WHERE = "action_where"
REASON = "action_reason"
CATEGORY = "action_category"

REASON_LIMIT = 2000

TABLE = None


def table():
    global TABLE
    if TABLE is None:
        TABLE = yaml.safe_load(ACTIONS_FILE.read_text())["actions"]
    return TABLE


def label(key):
    row = table().get(key)
    return row["label"] if row else key.replace("_", " ")


def needs_expiry(key):
    return bool(table().get(key, {}).get("expires"))


def needs_channel(key):
    return table().get(key, {}).get("channel") == "required"


def takes_channel(key):
    return bool(table().get(key, {}).get("channel"))


def choices():
    return [
        {"text": {"type": "plain_text", "text": row["label"]}, "value": key}
        for key, row in table().items()
    ]


def category_choices():
    return [edit.option(label, key) for key, label in edit.categories().items()]


def category_pick(held):
    picked = [one for one in category_choices() if one["value"] == held]
    return {"initial_option": picked[0]} if picked else {}


def kind_pick(held):
    picked = [one for one in choices() if one["value"] == held]
    return {"initial_option": picked[0]} if picked else {}


def opening(subjects=(), category=None):
    return {
        "target_user_id": subjects[0] if subjects else None,
        "category_key": category,
    }


def blocks(case_id, said):
    key = said.get("type_key")
    built = [
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": f"*case {case_id}*"}],
        },
        {
            "type": "input",
            "block_id": TARGET,
            "label": {"type": "plain_text", "text": "Against"},
            "element": {
                "type": "users_select",
                "action_id": TARGET,
                "placeholder": {"type": "plain_text", "text": "who it was aimed at"},
                **(
                    {"initial_user": said["target_user_id"]}
                    if said.get("target_user_id")
                    else {}
                ),
            },
        },
        {
            "type": "input",
            "block_id": KIND,
            "dispatch_action": True,
            "label": {"type": "plain_text", "text": "What was done"},
            "element": {
                "type": "static_select",
                "action_id": KIND,
                "placeholder": {"type": "plain_text", "text": "pick one"},
                "options": choices(),
                **kind_pick(key),
            },
        },
    ]

    if needs_expiry(key):
        built.append(
            {
                "type": "input",
                "block_id": UNTIL,
                "label": {"type": "plain_text", "text": "Until"},
                "element": {
                    "type": "datepicker",
                    "action_id": UNTIL,
                    **(
                        {"initial_date": said["expires_on"]}
                        if said.get("expires_on")
                        else {}
                    ),
                },
            }
        )

    if takes_channel(key):
        built.append(
            {
                "type": "input",
                "block_id": WHERE,
                "optional": not needs_channel(key),
                "label": {"type": "plain_text", "text": "Which channel"},
                "element": {
                    "type": "conversations_select",
                    "action_id": WHERE,
                    "placeholder": {"type": "plain_text", "text": "pick a channel"},
                    **(
                        {"initial_conversation": said["channel_id"]}
                        if said.get("channel_id")
                        else {}
                    ),
                },
            }
        )

    built += [
        {
            "type": "input",
            "block_id": CATEGORY,
            "optional": True,
            "label": {"type": "plain_text", "text": "The violation"},
            "element": {
                "type": "static_select",
                "action_id": CATEGORY,
                "placeholder": {"type": "plain_text", "text": "pick one"},
                "options": category_choices(),
                **category_pick(said.get("category_key")),
            },
        },
        {
            "type": "input",
            "block_id": REASON,
            "label": {"type": "plain_text", "text": "Resolution summary"},
            "element": {
                "type": "plain_text_input",
                "action_id": REASON,
                "multiline": True,
                "max_length": REASON_LIMIT,
                "placeholder": {"type": "plain_text", "text": "what they did"},
                **({"initial_value": said["reason"]} if said.get("reason") else {}),
            },
        },
    ]
    return built


def view(case_id, subjects=(), category=None, said=None):
    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": "Log an action"},
        "submit": {"type": "plain_text", "text": "Log it"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": blocks(case_id, said or opening(subjects, category)),
    }


def unasked(said, shown):
    key = said.get("type_key")
    if needs_expiry(key) and UNTIL not in shown:
        return True
    return needs_channel(key) and WHERE not in shown


def picked(view_state):
    values = view_state.get("values", {})
    return {
        "target_user_id": values.get(TARGET, {}).get(TARGET, {}).get("selected_user"),
        "type_key": (
            (values.get(KIND, {}).get(KIND, {}).get("selected_option") or {}).get("value")
        ),
        "expires_on": values.get(UNTIL, {}).get(UNTIL, {}).get("selected_date"),
        "channel_id": values.get(WHERE, {}).get(WHERE, {}).get("selected_conversation"),
        "reason": (values.get(REASON, {}).get(REASON, {}).get("value") or "").strip(),
        "category_key": (
            (values.get(CATEGORY, {}).get(CATEGORY, {}).get("selected_option") or {})
            .get("value")
        ),
    }


def objection(said):
    key = said.get("type_key")
    if not key:
        return {KIND: "Pick what was done."}
    if not said.get("target_user_id"):
        return {TARGET: "Say who it was aimed at."}
    if needs_expiry(key) and not said.get("expires_on"):
        return {UNTIL: f"A {label(key).lower()} needs a date it runs until."}
    if needs_channel(key) and not said.get("channel_id"):
        return {WHERE: f"A {label(key).lower()} needs a channel."}
    if not said.get("reason"):
        return {REASON: "Say why this was the answer."}
    return None


def details(said):
    if not takes_channel(said["type_key"]) or not said.get("channel_id"):
        return {}
    return {"channel_id": said["channel_id"]}
