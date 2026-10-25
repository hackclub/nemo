import datetime as dt
from zoneinfo import ZoneInfo

import yaml

from bot.core.formatting import short_date, short_end
from bot.nemo.views import edit, lengths, resolve
from lib.paths import ACTIONS_FILE

CALLBACK = "case_action_log"

TARGET = "action_target"
KIND = "action_kind"
UNTIL = "action_until"
UNTIL_TIME = "action_until_time"
WHERE = "action_where"
REASON = "action_reason"
SOLUTION = "action_solution"
RESOLVERS = "action_resolvers"
RESOLVE = "action_resolve"
NOTIFY = "action_notify"
MESSAGE = "action_message"
CATEGORY = "action_category"
GUARD_STATUS = "action_standing"
ENFORCEMENT = "action_settle"

RESOLVE_CASE = "resolve_case"
NOTIFY_REPORTER = "notify_reporter"

DEACTIVATION_GUARD = "deactivation"

NO_GUARD = "no_guard"
NO_CASE = "no_case"
OTHER_CASE = "other_case"
THIS_CASE = "this_case"

OPEN_GUARD = "apply"
ATTACH = "adopt"
EXTEND = "extend"
LOG_ONLY = "record"

DEFAULT_ENFORCEMENT = {
    NO_GUARD: OPEN_GUARD,
    NO_CASE: ATTACH,
    OTHER_CASE: LOG_ONLY,
    THIS_CASE: LOG_ONLY,
}

REASON_LIMIT = 2000

NO_REASON_CATEGORIES = ("adult",)

REQUIRED = "required"

TABLE = None


def table():
    global TABLE
    if TABLE is None:
        TABLE = yaml.safe_load(ACTIONS_FILE.read_text())["actions"]
    return TABLE


def label(key):
    row = table().get(key)
    return row["label"] if row else key.replace("_", " ")


def takes_expiry(key):
    return bool(table().get(key, {}).get("expires"))


def needs_expiry(key):
    return table().get(key, {}).get("expires") == REQUIRED


def enforce(key):
    return table().get(key, {}).get("enforce") or {}


def guard_kind(key):
    return enforce(key).get("guard")


def deactivates(key):
    return guard_kind(key) == DEACTIVATION_GUARD


def guard_scope(key):
    return enforce(key).get("scope")


def guard_mode(key):
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


def needs_reason(category_key):
    return category_key not in NO_REASON_CATEGORIES


def guard_reason(values):
    key = values.get("category_key")
    return values.get("reason") or edit.categories().get(key, key)


def category_initial_option(selected_key):
    matches = [one for one in category_choices() if one["value"] == selected_key]
    return {"initial_option": matches[0]} if matches else {}


def kind_initial_option(selected_key):
    matches = [one for one in choices() if one["value"] == selected_key]
    return {"initial_option": matches[0]} if matches else {}


def expiry(values):
    on = values.get("expires_on")
    if not on:
        return None
    zone = ZoneInfo(values["timezone"]) if values.get("timezone") else dt.UTC
    return lengths.end_at(on, values.get("expires_time"), zone)


def format_date(at):
    return short_date(at) if at else None


def format_end(at):
    return short_end(at) if at else None


def header_text(values, channel_name=None):
    key = values["type_key"]
    parts = [label(key)]
    if needs_channel(key) and values.get("channel_id"):
        parts.append(f"from #{channel_name}" if channel_name else f"from {values['channel_id']}")
    until = format_end(expiry(values))
    if takes_expiry(key) and until:
        parts.append(f"until {until}")
    return " ".join(parts)


def existing_action_text(guard):
    text = label(guard["kind"]).lower()
    where = guard.get("channel_id")
    return f"{text} in <#{where}>" if where else text


def case_attribution_text(guard, case_id):
    guard_case_id = guard.get("case_id")
    if guard_case_id is None:
        return "with no case"
    if case_id is not None and guard_case_id == case_id:
        return "on this case"
    return f"on *case {guard_case_id}*"


def footnote(guard):
    parts = [f"set by <@{guard['opened_by']}>"]
    since = format_date(guard.get("opened_at"))
    if since:
        parts.append(f"since {since}")
    until = format_end(guard.get("expires_at"))
    parts.append(f"until {until}" if until else "no end date")
    if guard.get("enforced_by") == "by_hand":
        parts.append("manual")
    elif guard.get("enforced_by") == "firehose":
        parts.append("Firehose")
    elif guard.get("enforcement_status") == "failed":
        parts.append("not enforced")
    elif guard.get("enforcement_status") == "pending":
        parts.append("pending")
    return ", ".join(parts)


def existing_guard_blocks(guard_status):
    guard = (guard_status or {}).get("guard")
    if not guard:
        return []

    return [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "<@{}> already has an active {} {}.".format(
                    guard["subject_id"], existing_action_text(guard), case_attribution_text(guard, guard_status.get("case_id"))
                ),
            },
        },
        {
            "type": "context",
            "block_id": GUARD_STATUS,
            "elements": [{"type": "mrkdwn", "text": footnote(guard)}],
        },
    ]


def enforcement_options(values, guard_status):
    guard_status = guard_status or {}
    if not guard_status.get("enforceable"):
        return []

    relation = guard_status.get("relation") or NO_GUARD
    if relation == NO_GUARD:
        return []
    if relation == NO_CASE:
        return [
            (ATTACH, "Attach to case"),
            (LOG_ONLY, "Log only"),
        ]

    built = []
    if takes_expiry(values.get("type_key")):
        built.append((EXTEND, "Update end date"))
    built.append((LOG_ONLY, "Log only"))
    return built if len(built) > 1 else []


def enforcement_blocks(values, guard_status):
    options = enforcement_options(values, guard_status)
    if not options:
        return []

    relation = (guard_status or {}).get("relation") or NO_GUARD
    selected = values.get("enforcement")
    if selected not in dict(options):
        selected = DEFAULT_ENFORCEMENT.get(relation, LOG_ONLY)

    built = [
        {"text": {"type": "plain_text", "text": text}, "value": value}
        for value, text in options
    ]
    matches = [one for one in built if one["value"] == selected]
    return [
        {
            "type": "input",
            "block_id": ENFORCEMENT,
            "label": {"type": "plain_text", "text": "Enforcement"},
            "element": {
                "type": "radio_buttons",
                "action_id": ENFORCEMENT,
                "options": built,
                **({"initial_option": matches[0]} if matches else {}),
            },
        }
    ]


def initial_values(subjects=(), category=None):
    return {
        "target_user_id": subjects[0] if subjects else None,
        "category_key": category,
    }


def build_blocks(case_id, values, guard_status=None, end_error=None, open_report=False):
    key = values.get("type_key")
    built = [
        {
            "type": "input",
            "block_id": TARGET,
            "dispatch_action": True,
            "label": {"type": "plain_text", "text": "Member"},
            "element": {
                "type": "users_select",
                "action_id": TARGET,
                "placeholder": {"type": "plain_text", "text": "Select a member"},
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
                "placeholder": {"type": "plain_text", "text": "Select an action"},
                "options": choices(),
                **kind_initial_option(key),
            },
        },
    ]

    built += existing_guard_blocks(guard_status)

    if takes_expiry(key):
        built += lengths.end_row(
            UNTIL, "End" if needs_expiry(key) else "End, optional",
            (values.get("expires_on"), values.get("expires_time")), end_error,
            date_action=UNTIL, time_action=UNTIL_TIME,
        )

    if takes_channel(key):
        built.append(
            {
                "type": "input",
                "block_id": WHERE,
                "dispatch_action": True,
                "optional": not needs_channel(key),
                "label": {"type": "plain_text", "text": "Channel"},
                "element": {
                    "type": "conversations_select",
                    "action_id": WHERE,
                    "placeholder": {"type": "plain_text", "text": "Select a channel"},
                    **(
                        {"initial_conversation": values["channel_id"]}
                        if values.get("channel_id")
                        else {}
                    ),
                },
            }
        )

    built += enforcement_blocks(values, guard_status)

    built.append(
        {
            "type": "input",
            "block_id": CATEGORY,
            "dispatch_action": True,
            "optional": True,
            "label": {"type": "plain_text", "text": "Violation"},
            "element": {
                "type": "static_select",
                "action_id": CATEGORY,
                "placeholder": {"type": "plain_text", "text": "Select a violation"},
                "options": category_choices(),
                **category_initial_option(values.get("category_key")),
            },
        }
    )
    if needs_reason(values.get("category_key")):
        built.append(
            {
                "type": "input",
                "block_id": REASON,
                "label": {"type": "plain_text", "text": "Reason"},
                "element": {
                    "type": "plain_text_input",
                    "action_id": REASON,
                    "multiline": True,
                    "max_length": REASON_LIMIT,
                    **({"initial_value": values["reason"]} if values.get("reason") else {}),
                },
            }
        )
    built += [
        {
            "type": "input",
            "block_id": SOLUTION,
            "optional": True,
            "label": {"type": "plain_text", "text": "How Was This Solved? (Text edition)"},
            "element": {
                "type": "plain_text_input",
                "action_id": SOLUTION,
                "multiline": True,
                "max_length": REASON_LIMIT,
                **({"initial_value": values["solution"]} if values.get("solution") else {}),
            },
        },
        {
            "type": "input",
            "block_id": RESOLVERS,
            "optional": True,
            "label": {"type": "plain_text", "text": "Who Resolved This? (Thank you btw <3)"},
            "element": {
                "type": "multi_users_select",
                "action_id": RESOLVERS,
                "placeholder": {"type": "plain_text", "text": "Select people"},
                **({"initial_users": values["resolved_by"]} if values.get("resolved_by") else {}),
            },
        },
        resolve_block(values.get("resolve_case")),
    ]
    if values.get("resolve_case") and open_report:
        built += notify_blocks(values)
    return built


RESOLVE_OPTION = {"text": {"type": "plain_text", "text": "Yes"}, "value": RESOLVE_CASE}
NOTIFY_OPTION = {"text": {"type": "plain_text", "text": "Yes"}, "value": NOTIFY_REPORTER}


def tick_block(block_id, label, option, checked):
    return {
        "type": "input",
        "block_id": block_id,
        "dispatch_action": True,
        "optional": True,
        "label": {"type": "plain_text", "text": label},
        "element": {
            "type": "checkboxes",
            "action_id": block_id,
            "options": [option],
            **({"initial_options": [option]} if checked else {}),
        },
    }


def resolve_block(checked):
    return tick_block(RESOLVE, "Resolve Case?", RESOLVE_OPTION, checked)


def notify_blocks(values):
    notify = values.get("notify_reporter", True)
    built = [tick_block(NOTIFY, "Notify the reporter", NOTIFY_OPTION, notify)]
    if notify:
        built.append({
            "type": "input",
            "block_id": MESSAGE,
            "label": {"type": "plain_text", "text": "Message to reporter"},
            "element": {
                "type": "plain_text_input",
                "action_id": MESSAGE,
                "multiline": True,
                "max_length": REASON_LIMIT,
                "initial_value": values.get("message") or resolve.default_message(),
            },
        })
    return built


def build_view(case_id, subjects=(), category=None, values=None, guard_status=None, end_error=None,
               open_report=False):
    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": str(case_id),
        "title": {"type": "plain_text", "text": "Log action"},
        "submit": {"type": "plain_text", "text": "Log"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": build_blocks(case_id, values or initial_values(subjects, category), guard_status, end_error,
                               open_report),
    }


HEADER_TEXT_LIMIT = 150


def resolvers(values, by):
    return list(values.get("resolved_by") or []) or [by]


def byline(values, by):
    text = f"Against <@{values['target_user_id']}>, logged by <@{by}>"
    resolved_by = resolvers(values, by)
    if resolved_by != [by]:
        text += ", resolved by " + ", ".join(f"<@{one}>" for one in resolved_by)
    return text


def log_blocks(values, by, channel_name=None):
    built = [
        {
            "type": "header",
            "text": {"type": "plain_text",
                      "text": header_text(values, channel_name)[:HEADER_TEXT_LIMIT]},
        },
        {
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": byline(values, by)}],
        },
    ]
    if values.get("reason"):
        built += [
            {"type": "divider"},
            {"type": "section", "text": {"type": "mrkdwn", "text": f"> {values['reason']}"}},
        ]
    if values.get("solution"):
        built.append({
            "type": "context",
            "elements": [{
                "type": "mrkdwn",
                "text": f"*How Was This Solved?* {values['solution']}",
            }],
        })
    return built


def requires_refresh(values, block_ids, guard_status=None, open_report=False):
    key = values.get("type_key")
    if values.get("resolve_case") and open_report and NOTIFY not in block_ids:
        return True
    if takes_expiry(key) and UNTIL not in block_ids:
        return True
    if needs_channel(key) and WHERE not in block_ids:
        return True
    if CATEGORY in block_ids and needs_reason(values.get("category_key")) and REASON not in block_ids:
        return True
    if (guard_status or {}).get("guard") and GUARD_STATUS not in block_ids:
        return True
    return bool(enforcement_options(values, guard_status)) and ENFORCEMENT not in block_ids


def ticked(values, block_id, value):
    return any(
        one.get("value") == value
        for one in values.get(block_id, {}).get(block_id, {}).get("selected_options") or []
    )


def submitted_values(view_state):
    values = view_state.get("values", {})
    return {
        "target_user_id": values.get(TARGET, {}).get(TARGET, {}).get("selected_user"),
        "type_key": (
            (values.get(KIND, {}).get(KIND, {}).get("selected_option") or {}).get("value")
        ),
        "expires_on": values.get(UNTIL, {}).get(UNTIL, {}).get("selected_date"),
        "expires_time": values.get(UNTIL, {}).get(UNTIL_TIME, {}).get("selected_time"),
        "channel_id": values.get(WHERE, {}).get(WHERE, {}).get("selected_conversation"),
        "enforcement": (
            (values.get(ENFORCEMENT, {}).get(ENFORCEMENT, {}).get("selected_option") or {}).get("value")
        ),
        "reason": (values.get(REASON, {}).get(REASON, {}).get("value") or "").strip(),
        "solution": (values.get(SOLUTION, {}).get(SOLUTION, {}).get("value") or "").strip(),
        "resolved_by": values.get(RESOLVERS, {}).get(RESOLVERS, {}).get("selected_users") or [],
        "resolve_case": ticked(values, RESOLVE, RESOLVE_CASE),
        "notify_reporter": ticked(values, NOTIFY, NOTIFY_REPORTER) if NOTIFY in values else True,
        "message": (values.get(MESSAGE, {}).get(MESSAGE, {}).get("value") or "").strip() or None,
        "category_key": (
            (values.get(CATEGORY, {}).get(CATEGORY, {}).get("selected_option") or {})
            .get("value")
        ),
    }


def validation_errors(values):
    key = values.get("type_key")
    if not key:
        return {KIND: "Select an action"}
    if not values.get("target_user_id"):
        return {TARGET: "Select a member"}
    if needs_expiry(key) and not values.get("expires_on"):
        return {UNTIL: f"A {label(key).lower()} needs an end date."}
    if values.get("expires_time") and not values.get("expires_on"):
        return {UNTIL: "Pick a date for the end time."}
    if needs_channel(key) and not values.get("channel_id"):
        return {WHERE: "Select a channel"}
    if values.get("enforcement") == EXTEND and not values.get("expires_on"):
        return {UNTIL: "Select an end date"}
    if needs_reason(values.get("category_key")) and not values.get("reason"):
        return {REASON: "Add a reason."}
    return None


def details(values):
    if not takes_channel(values["type_key"]) or not values.get("channel_id"):
        return {}
    return {"channel_id": values["channel_id"]}
