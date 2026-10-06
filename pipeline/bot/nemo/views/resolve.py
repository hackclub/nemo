import yaml

from bot.core import richtext
from bot.nemo.views import action
from lib.paths import RESOLUTIONS_FILE

CALLBACK = "case_resolve"

TITLE_LIMIT = 24

WHY = "resolve_why"
NOTE = "resolve_note"
TELL = "resolve_tell"
MESSAGE = "resolve_message"

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


def default_message():
    return table()["told"]


def reasons():
    submitted_values = {
        key: row
        for key, row in table()["resolutions"].items()
        if row.get("pick")
    }
    return sorted(submitted_values, key=lambda key: submitted_values[key]["pick"])


def forced(live_actions):
    return "action_taken" if live_actions else None


def until(at):
    return at.strftime("%-d %b") if at else None


def line(one):
    message = f"<@{one['target_user_id']}> - {action.label(one['type_key']).lower()}"
    where = (one.get("details") or {}).get("channel_id")
    if where:
        message += f" in <#{where}>"
    ends = until(one.get("expires_at"))
    if ends:
        message += f" until {ends}"
    return message


def taken(live_actions):
    return "\n".join(line(one) for one in live_actions)


def reason_input_block(live_actions):
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


def build_view(case_id, live_actions=(), open_reports=0):
    blocks = [
        reason_input_block(live_actions),
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
                "block_id": MESSAGE,
                "optional": True,
                "label": {"type": "plain_text", "text": "What they are told"},
                "element": {
                    "type": "plain_text_input",
                    "action_id": MESSAGE,
                    "multiline": True,
                    "initial_value": default_message(),
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


def submitted_values(view_state, live_actions=()):
    values = view_state.get("values", {})
    chosen = (values.get(WHY, {}).get(WHY, {}).get("selected_option") or {}).get("value")
    ticked = values.get(TELL, {}).get(TELL, {}).get("selected_options") or []
    message = values.get(MESSAGE, {}).get(MESSAGE, {}).get("value")

    note = richtext.flatten(values.get(NOTE, {}).get(NOTE, {}).get("rich_text_value"))

    return {
        "resolution": forced(live_actions) or chosen,
        "member_note": note or None,
        "telling": any(one.get("value") == TELLING for one in ticked),
        "message": (message or "").strip() or default_message(),
    }


def validation_errors(values):
    if not values.get("resolution"):
        return {WHY: "Say why this case is closing."}
    if values.get("telling") and richtext.mentions(values.get("message")):
        return {MESSAGE: "The reporter cannot be sent a mention. Say it in words."}
    return None


def by_line(resolution, by):
    if resolution == "action_taken":
        return f"Resolved by <@{by}>"
    return f"Resolved by <@{by}> · {label(resolution).lower()}"


def action_group_blocks(one):
    built = [{
        "type": "context",
        "elements": [{
            "type": "mrkdwn",
            "text": f"*{action.label(one['type_key'])}* against <@{one['target_user_id']}>",
        }],
    }]
    if one.get("reason"):
        built.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"> {one['reason']}"},
        })
    return built


def echo_blocks(resolution, member_note, by, actions=()):
    built = [{
        "type": "context",
        "elements": [{"type": "mrkdwn", "text": by_line(resolution, by)}],
    }]

    if resolution == "action_taken":
        if actions:
            built.append({"type": "divider"})
            for one in actions:
                built.extend(action_group_blocks(one))
        if member_note:
            built.append({
                "type": "context",
                "elements": [{
                    "type": "mrkdwn",
                    "text": f"*How it was solved:* {member_note}",
                }],
            })
    elif member_note:
        built.append({"type": "divider"})
        built.append({
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"> {member_note}"},
        })

    return built
