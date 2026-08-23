import yaml

from lib.paths import ACTIONS_FILE

CALLBACK = "case_action_log"

TARGET = "action_target"
KIND = "action_kind"
UNTIL = "action_until"
WHERE = "action_where"

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


def view(case_id, subjects=()):
    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": "Log an action"},
        "submit": {"type": "plain_text", "text": "Log it"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": [
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": f"case *{case_id}*"}],
            },
            {
                "type": "input",
                "block_id": TARGET,
                "label": {"type": "plain_text", "text": "Against"},
                "element": {
                    "type": "users_select",
                    "action_id": TARGET,
                    "placeholder": {"type": "plain_text", "text": "who it was aimed at"},
                    **({"initial_user": subjects[0]} if subjects else {}),
                },
            },
            {
                "type": "input",
                "block_id": KIND,
                "label": {"type": "plain_text", "text": "What was done"},
                "element": {
                    "type": "static_select",
                    "action_id": KIND,
                    "placeholder": {"type": "plain_text", "text": "pick one"},
                    "options": choices(),
                },
            },
            {
                "type": "input",
                "block_id": UNTIL,
                "optional": True,
                "label": {"type": "plain_text", "text": "Until"},
                "hint": {
                    "type": "plain_text",
                    "text": "A shush, a temporary ban and a channel ban all need a date.",
                },
                "element": {"type": "datepicker", "action_id": UNTIL},
            },
            {
                "type": "input",
                "block_id": WHERE,
                "optional": True,
                "label": {"type": "plain_text", "text": "Which channel"},
                "hint": {"type": "plain_text", "text": "A channel ban needs one."},
                "element": {
                    "type": "conversations_select",
                    "action_id": WHERE,
                    "placeholder": {"type": "plain_text", "text": "pick a channel"},
                },
            },
        ],
    }


def picked(view_state):
    values = view_state.get("values", {})
    return {
        "target_user_id": values.get(TARGET, {}).get(TARGET, {}).get("selected_user"),
        "type_key": (
            (values.get(KIND, {}).get(KIND, {}).get("selected_option") or {}).get("value")
        ),
        "expires_on": values.get(UNTIL, {}).get(UNTIL, {}).get("selected_date"),
        "channel_id": values.get(WHERE, {}).get(WHERE, {}).get("selected_conversation"),
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
    return None


def details(said):
    if not takes_channel(said["type_key"]) or not said.get("channel_id"):
        return {}
    return {"channel_id": said["channel_id"]}


def told(said, case_id):
    return f"{label(said['type_key']).lower()} logged on case {case_id}"
