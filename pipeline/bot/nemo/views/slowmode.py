import datetime as dt
import json

from bot.nemo.views import lengths, removal

CALLBACK = "thread_slowmode"
DISABLED_CALLBACK = "thread_slowmode_disabled"

END = "slowmode_end"
SECONDS = "slowmode_seconds"
REASON = "slowmode_reason"
EXEMPT = "slowmode_exempt"
DISABLE = "slowmode_off"

TITLE = "Slow mode"
REASON_LIMIT = 500
MIN_SECONDS = 1
MAX_SECONDS = 3600
DEFAULT_SECONDS = 30


def metadata(channel_id, thread_ts, extend=False):
    values = {"channel_id": channel_id, "thread_ts": thread_ts}
    if extend:
        values["extend"] = True
    return json.dumps(values)


def is_extending(view):
    try:
        return bool(json.loads(view.get("private_metadata") or "{}").get("extend"))
    except ValueError:
        return False


def parse_metadata(view):
    try:
        values = json.loads(view.get("private_metadata") or "{}")
    except ValueError:
        return None, None
    return values.get("channel_id"), values.get("thread_ts")


def cooldown(seconds):
    if seconds >= 60 and seconds % 60 == 0:
        return f"{seconds // 60}m"
    return f"{seconds}s"


def summary(seconds, expires_at):
    return f"{cooldown(seconds)} cooldown {lengths.ends(expires_at)}"


plain = lengths.plain


def seconds_block(seconds=None):
    return {"type": "input", "block_id": SECONDS, "label": plain("Cooldown (seconds)"),
            "element": {"type": "number_input", "action_id": SECONDS, "is_decimal_allowed": False,
                        "min_value": str(MIN_SECONDS), "max_value": str(MAX_SECONDS),
                        "initial_value": str(seconds or DEFAULT_SECONDS)}}


def reason_block(reason=None):
    element = {"type": "plain_text_input", "action_id": REASON, "multiline": True,
               "max_length": REASON_LIMIT}
    if reason:
        element["initial_value"] = reason
    return {"type": "input", "block_id": REASON, "label": plain("Reason"), "element": element}


def exempt_block(user_ids=()):
    element = {"type": "multi_users_select", "action_id": EXEMPT}
    if user_ids:
        element["initial_users"] = list(user_ids)
    return {"type": "input", "block_id": EXEMPT, "optional": True,
            "label": plain("Exempt members"), "element": element}


def status_block(current, now=None):
    return {
        "type": "section",
        "text": {"type": "mrkdwn",
                 "text": f"*Enabled* {lengths.remaining(current['expires_at'], now)}, "
                         f"set by <@{current['opened_by']}>"},
        "accessory": {
            "type": "button", "action_id": DISABLE, "style": "danger", "text": plain("Disable"),
            "confirm": {"title": plain("Disable slow mode"),
                        "text": {"type": "mrkdwn", "text": "Disable slow mode in this thread."},
                        "confirm": plain("Disable"), "deny": plain("Cancel"), "style": "danger"},
        },
    }


def build_view(channel_id, thread_ts, current=None, tz=dt.UTC, values=None, end_error=None, now=None):
    values = values or {}
    initial = (values.get("end_date"), values.get("end_time"))
    if current and not any(initial):
        initial = lengths.initial_of(current["expires_at"], tz)
    seconds = values.get("seconds") or (current and current["seconds"])
    reason = values.get("reason") or (current and current["reason"])
    exempt = values["exempt"] if "exempt" in values else (current["exempt"] if current else ())
    blocks = [status_block(current, now)] if current else []
    blocks += lengths.end_row(END, "End, optional", initial, end_error, tz=tz)
    blocks += [seconds_block(seconds), reason_block(reason), exempt_block(exempt)]
    return {
        "type": "modal",
        "callback_id": CALLBACK,
        "private_metadata": metadata(channel_id, thread_ts, extend=bool(current)),
        "title": plain(TITLE),
        "submit": plain("Save" if current else "Enable"),
        "close": plain("Cancel"),
        "blocks": blocks,
    }


def disabled_view():
    return {
        "type": "modal",
        "callback_id": DISABLED_CALLBACK,
        "title": plain(TITLE),
        "close": plain("Close"),
        "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": "*Disabled*"}}],
    }


def submitted_values(state, extending=False):
    values = state.get("values", {})
    end_date, end_time = lengths.picked(values, END)
    return {
        "starting": not extending,
        "end_date": end_date,
        "end_time": end_time,
        "seconds": values.get(SECONDS, {}).get(SECONDS, {}).get("value"),
        "reason": (values.get(REASON, {}).get(REASON, {}).get("value") or "").strip(),
        "exempt": values.get(EXEMPT, {}).get(EXEMPT, {}).get("selected_users") or [],
    }


def parse_seconds(values):
    try:
        seconds = int(str(values.get("seconds") or "").strip())
    except ValueError:
        return None
    return seconds if MIN_SECONDS <= seconds <= MAX_SECONDS else None


def new_end(values, tz=dt.UTC, current=None):
    ends = lengths.end_at(values["end_date"], values["end_time"], tz)
    if ends is None and not values["starting"] and current:
        return current["expires_at"]
    return ends


def validation_errors(values, tz=dt.UTC, now=None):
    if parse_seconds(values) is None:
        return {SECONDS: f"Enter {MIN_SECONDS} to {MAX_SECONDS} seconds."}
    if not values["reason"]:
        return {REASON: "Add a reason."}
    message = lengths.end_error(values["end_date"], values["end_time"], new_end(values, tz), now=now)
    return {END: message} if message else None


def notice(seconds, expires_at):
    text = f"*Slow mode enabled* with {summary(seconds, expires_at)}"
    return {
        "text": text,
        "blocks": [
            {"type": "section", "text": {"type": "mrkdwn", "text": text}},
        ],
    }


def removal_notice(seconds_remaining, body, in_thread):
    what = "reply" if in_thread else "message"
    text = f"*Slow mode*: next {what} in {format_wait(seconds_remaining)}"
    return removal.notice(text, body)


def format_wait(seconds):
    if seconds < 60:
        return f"{seconds}s"
    return f"{(seconds + 59) // 60}m"
