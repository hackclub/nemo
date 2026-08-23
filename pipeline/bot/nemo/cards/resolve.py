import yaml

from bot.engine import richtext
from bot.nemo.cards import action
from lib.paths import RESOLUTIONS_FILE

CALLBACK = "case_resolve"

TITLE_LIMIT = 24

WHY = "resolve_why"
NOTE = "resolve_note"
TELL = "resolve_tell"
SAID = "resolve_said"

TELLING = "tell_them"

TABLE = None


def table():
    global TABLE
    if TABLE is None:
        TABLE = yaml.safe_load(RESOLUTIONS_FILE.read_text())
    return TABLE


def label(key):
    row = table()["resolutions"].get(key)
    return row["label"] if row else key.replace("_", " ")


def told():
    return table()["told"]


def reasons():
    picked = {
        key: row
        for key, row in table()["resolutions"].items()
        if row.get("pick")
    }
    return sorted(picked, key=lambda key: picked[key]["pick"])


def forced(live_actions):
    return "action_taken" if live_actions else None


def until(at):
    return at.strftime("%-d %b") if at else None


def line(one):
    said = f"<@{one['target_user_id']}> - {action.label(one['type_key']).lower()}"
    where = (one.get("details") or {}).get("channel_id")
    if where:
        said += f" in <#{where}>"
    ends = until(one.get("expires_at"))
    if ends:
        said += f" until {ends}"
    return said


def taken(live_actions):
    return "\n".join(line(one) for one in live_actions)


def why_block(live_actions):
    if forced(live_actions):
        return {"type": "section", "text": {"type": "mrkdwn", "text": taken(live_actions)}}

    return {
        "type": "input",
        "block_id": WHY,
        "label": {"type": "plain_text", "text": "Why it is closing"},
        "element": {
            "type": "static_select",
            "action_id": WHY,
            "options": [
                {"text": {"type": "plain_text", "text": label(key)}, "value": key}
                for key in reasons()
            ],
        },
    }


def view(case_id, live_actions=(), open_reports=0):
    blocks = [
        why_block(live_actions),
        {
            "type": "input",
            "block_id": NOTE,
            "optional": True,
            "label": {"type": "plain_text", "text": "For the record"},
            "element": {
                "type": "rich_text_input",
                "action_id": NOTE,
                "min_lines": 2,
                "placeholder": {
                    "type": "plain_text",
                    "text": "what happened",
                },
            },
        },
    ]

    if open_reports:
        blocks += [
            {
                "type": "input",
                "block_id": TELL,
                "optional": True,
                "label": {"type": "plain_text", "text": "The reporter"},
                "element": {
                    "type": "checkboxes",
                    "action_id": TELL,
                    "options": [
                        {
                            "text": {"type": "plain_text", "text": "Tell them it is closed"},
                            "value": TELLING,
                        }
                    ],
                    "initial_options": [
                        {
                            "text": {"type": "plain_text", "text": "Tell them it is closed"},
                            "value": TELLING,
                        }
                    ],
                },
            },
            {
                "type": "input",
                "block_id": SAID,
                "optional": True,
                "label": {"type": "plain_text", "text": "What they are told"},
                "element": {
                    "type": "plain_text_input",
                    "action_id": SAID,
                    "multiline": True,
                    "initial_value": told(),
                },
            },
        ]

    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": f"Resolve · case {case_id}"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Resolve"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": blocks,
    }


def picked(view_state, live_actions=()):
    values = view_state.get("values", {})
    chosen = (values.get(WHY, {}).get(WHY, {}).get("selected_option") or {}).get("value")
    ticked = values.get(TELL, {}).get(TELL, {}).get("selected_options") or []
    said = values.get(SAID, {}).get(SAID, {}).get("value")

    note = richtext.flatten(values.get(NOTE, {}).get(NOTE, {}).get("rich_text_value"))

    return {
        "resolution": forced(live_actions) or chosen,
        "member_note": note or None,
        "telling": any(one.get("value") == TELLING for one in ticked),
        "said": (said or "").strip() or told(),
    }


def objection(said):
    if not said.get("resolution"):
        return {WHY: "Say why this case is closing."}
    if said.get("telling") and richtext.mentions(said.get("said")):
        return {SAID: "The reporter cannot be sent a mention. Say it in words."}
    return None


def done(said, case_id, told):
    closed = f"*case {case_id}* closed as {label(said['resolution']).lower()}"
    if not told:
        return closed
    return f"{closed}, {told} reporter" + ("s told" if told != 1 else " told")
