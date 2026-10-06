import yaml

from bot.nemo.views import edit
from lib.paths import ACTIONS_FILE

CALLBACK = "case_action_log"

TARGET = "action_target"
KIND = "action_kind"
RESOLUTION_NOTE = "action_resolution_note"
UNTIL = "action_until"
WHERE = "action_where"
REASON = "action_reason"
CATEGORY = "action_category"
STANDING = "action_standing"
SETTLE = "action_settle"

UNGUARDED = "unguarded"
ORPHANED = "orphaned"
ELSEWHERE = "elsewhere"
HERE = "here"

CARRY = "carry"
ADOPT = "adopt"
EXTEND = "extend"
RECORD = "record"

SETTLE_DEFAULT = {
    UNGUARDED: CARRY,
    ORPHANED: ADOPT,
    ELSEWHERE: RECORD,
    HERE: RECORD,
}

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


def enforce(key):
    return table().get(key, {}).get("enforce") or {}


def guard_kind(key):
    return enforce(key).get("guard")


def guard_scope(key):
    return enforce(key).get("scope")


def guard_carry(key):
    return enforce(key).get("carry")


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
    submitted_values = [one for one in category_choices() if one["value"] == held]
    return {"initial_option": submitted_values[0]} if submitted_values else {}


def kind_pick(held):
    submitted_values = [one for one in choices() if one["value"] == held]
    return {"initial_option": submitted_values[0]} if submitted_values else {}


def expiry(values):
    on = values.get("expires_on")
    return f"{on} 23:59:59" if on else None


def format_date(at):
    return at.strftime("%-d %b") if at else None


def existing_action_text(found):
    text = label(found["kind"]).lower()
    where = found.get("channel_id")
    return f"{text} in <#{where}>" if where else text


def case_attribution_text(found, case_id):
    held = found.get("case_id")
    if held is None:
        return "on no case"
    if case_id is not None and held == case_id:
        return "on this case"
    return f"under *case {held}*"


def footnote(found):
    parts = [f"opened by <@{found['opened_by']}>"]
    since = format_date(found.get("opened_at"))
    if since:
        parts.append(f"since {since}")
    until = format_date(found.get("expires_at"))
    parts.append(f"until {until}" if until else "with no end date")
    if found.get("enforced_by") == "by_hand":
        parts.append("done by hand")
    elif found.get("enforcement_status") == "failed":
        parts.append("nemo is not holding it")
    elif found.get("enforcement_status") == "pending":
        parts.append("nemo has not carried it yet")
    return "  ·  ".join(parts)


def standing_blocks(standing):
    found = (standing or {}).get("found")
    if not found:
        return []

    return [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": ":warning: <@{}> is already {} {}.".format(
                    found["subject_id"], existing_action_text(found), case_attribution_text(found, standing.get("case_id"))
                ),
            },
        },
        {
            "type": "context",
            "block_id": STANDING,
            "elements": [{"type": "mrkdwn", "text": footnote(found)}],
        },
    ]


def settle_options(values, standing):
    standing = standing or {}
    if not standing.get("enforceable"):
        return []

    reads = standing.get("reads") or UNGUARDED
    if reads == UNGUARDED:
        return []
    if reads == ORPHANED:
        return [
            (ADOPT, "Attach it to this case"),
            (RECORD, "Leave it where it is, just record this"),
        ]

    built = []
    if needs_expiry(values.get("type_key")):
        built.append((EXTEND, "Change it to the date above"))
    built.append((RECORD, "Just record this"))
    return built if len(built) > 1 else []


def settle_blocks(values, standing):
    options = settle_options(values, standing)
    if not options:
        return []

    reads = (standing or {}).get("reads") or UNGUARDED
    held = values.get("settle")
    if held not in dict(options):
        held = SETTLE_DEFAULT.get(reads, RECORD)

    built = [
        {"text": {"type": "plain_text", "text": text}, "value": value}
        for value, text in options
    ]
    submitted_values = [one for one in built if one["value"] == held]
    return [
        {
            "type": "input",
            "block_id": SETTLE,
            "label": {"type": "plain_text", "text": "Enforcement"},
            "element": {
                "type": "radio_buttons",
                "action_id": SETTLE,
                "options": built,
                **({"initial_option": submitted_values[0]} if submitted_values else {}),
            },
        }
    ]


def initial_values(subjects=(), category=None):
    return {
        "target_user_id": subjects[0] if subjects else None,
        "category_key": category,
    }


def build_blocks(case_id, values, standing=None):
    key = values.get("type_key")
    built = [
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": f"*case {case_id}*"}],
        },
        {
            "type": "input",
            "block_id": TARGET,
            "dispatch_action": True,
            "label": {"type": "plain_text", "text": "Logging record on individual"},
            "element": {
                "type": "users_select",
                "action_id": TARGET,
                "placeholder": {"type": "plain_text", "text": "who this is about"},
                **(
                    {"initial_user": values["target_user_id"]}
                    if values.get("target_user_id")
                    else {}
                ),
            },
        },
        {
            "type": "input",
            "block_id": KIND,
            "dispatch_action": True,
            "label": {"type": "plain_text", "text": "Action"},
            "element": {
                "type": "static_select",
                "action_id": KIND,
                "placeholder": {"type": "plain_text", "text": "pick one"},
                "options": choices(),
                **kind_pick(key),
            },
        },
        {
            "type": "input",
            "block_id": RESOLUTION_NOTE,
            "optional": True,
            "label": {"type": "plain_text", "text": "How was this solved? (optional)"},
            "element": {
                "type": "plain_text_input",
                "action_id": RESOLUTION_NOTE,
                "multiline": True,
                "max_length": REASON_LIMIT,
                "placeholder": {"type": "plain_text", "text": "what fixed it, if anything"},
                **(
                    {"initial_value": values["resolution_note"]}
                    if values.get("resolution_note")
                    else {}
                ),
            },
        },
    ]

    built += standing_blocks(standing)

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
                        {"initial_date": values["expires_on"]}
                        if values.get("expires_on")
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
                "dispatch_action": True,
                "optional": not needs_channel(key),
                "label": {"type": "plain_text", "text": "Which channel"},
                "element": {
                    "type": "conversations_select",
                    "action_id": WHERE,
                    "placeholder": {"type": "plain_text", "text": "pick a channel"},
                    **(
                        {"initial_conversation": values["channel_id"]}
                        if values.get("channel_id")
                        else {}
                    ),
                },
            }
        )

    built += settle_blocks(values, standing)

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
                **category_pick(values.get("category_key")),
            },
        },
        {
            "type": "input",
            "block_id": REASON,
            "label": {"type": "plain_text", "text": "What did they do?"},
            "element": {
                "type": "plain_text_input",
                "action_id": REASON,
                "multiline": True,
                "max_length": REASON_LIMIT,
                "placeholder": {"type": "plain_text", "text": "what they did"},
                **({"initial_value": values["reason"]} if values.get("reason") else {}),
            },
        },
    ]
    return built


def build_view(case_id, subjects=(), category=None, values=None, standing=None):
    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": "Log an action"},
        "submit": {"type": "plain_text", "text": "Log it"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": build_blocks(case_id, values or initial_values(subjects, category), standing),
    }


HEADER_TEXT_LIMIT = 150


def echo_blocks(values, by):
    built = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": label(values["type_key"])[:HEADER_TEXT_LIMIT]},
        },
        {
            "type": "context",
            "elements": [{
                "type": "mrkdwn",
                "text": f"Against <@{values['target_user_id']}> · logged by <@{by}>",
            }],
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"> {values['reason']}"},
        },
    ]
    if values.get("resolution_note"):
        built.append({
            "type": "context",
            "elements": [{
                "type": "mrkdwn",
                "text": f"*How it was solved:* {values['resolution_note']}",
            }],
        })
    return built


def requires_refresh(values, shown, standing=None):
    key = values.get("type_key")
    if needs_expiry(key) and UNTIL not in shown:
        return True
    if needs_channel(key) and WHERE not in shown:
        return True
    if (standing or {}).get("found") and STANDING not in shown:
        return True
    return bool(settle_options(values, standing)) and SETTLE not in shown


def submitted_values(view_state):
    values = view_state.get("values", {})
    return {
        "target_user_id": values.get(TARGET, {}).get(TARGET, {}).get("selected_user"),
        "type_key": (
            (values.get(KIND, {}).get(KIND, {}).get("selected_option") or {}).get("value")
        ),
        "resolution_note": (
            values.get(RESOLUTION_NOTE, {}).get(RESOLUTION_NOTE, {}).get("value") or ""
        ).strip(),
        "expires_on": values.get(UNTIL, {}).get(UNTIL, {}).get("selected_date"),
        "channel_id": values.get(WHERE, {}).get(WHERE, {}).get("selected_conversation"),
        "settle": (
            (values.get(SETTLE, {}).get(SETTLE, {}).get("selected_option") or {}).get("value")
        ),
        "reason": (values.get(REASON, {}).get(REASON, {}).get("value") or "").strip(),
        "category_key": (
            (values.get(CATEGORY, {}).get(CATEGORY, {}).get("selected_option") or {})
            .get("value")
        ),
    }


def validation_errors(values):
    key = values.get("type_key")
    if not key:
        return {KIND: "Pick an action."}
    if not values.get("target_user_id"):
        return {TARGET: "Say who this is about."}
    if needs_expiry(key) and not values.get("expires_on"):
        return {UNTIL: f"A {label(key).lower()} needs a date it runs until."}
    if needs_channel(key) and not values.get("channel_id"):
        return {WHERE: f"A {label(key).lower()} needs a channel."}
    if values.get("settle") == EXTEND and not values.get("expires_on"):
        return {UNTIL: f"Say the date the {label(key).lower()} should run until."}
    if not values.get("reason"):
        return {REASON: "Say why this was the answer."}
    return None


def details(values):
    if not takes_channel(values["type_key"]) or not values.get("channel_id"):
        return {}
    return {"channel_id": values["channel_id"]}
