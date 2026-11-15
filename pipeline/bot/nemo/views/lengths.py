import datetime as dt
import re

from bot.core.formatting import short_end, short_end_token

END_OF_DAY = dt.time(23, 59, 59)

DURATION = re.compile(r"\A(\d{1,6})([mhdw])\Z", re.IGNORECASE)
DURATION_UNITS = {"m": "minutes", "h": "hours", "d": "days", "w": "weeks"}
MAX_DURATION_DAYS = 365
MIN_DURATION = dt.timedelta(minutes=1)
MAX_DURATION = dt.timedelta(days=MAX_DURATION_DAYS)

DATE_SUFFIX = "_date"
TIME_SUFFIX = "_time"


def plain(text):
    return {"type": "plain_text", "text": text}


def initial_of(at, tz=dt.UTC):
    if not at:
        return None, None
    local = at.astimezone(tz)
    return local.date().isoformat(), local.strftime("%H:%M")


def end_row(block_id, label, initial=(None, None), error=None, date_action=None, time_action=None):
    date_element = {"type": "datepicker", "action_id": date_action or f"{block_id}{DATE_SUFFIX}",
                    "placeholder": plain("Select a date")}
    time_element = {"type": "timepicker", "action_id": time_action or f"{block_id}{TIME_SUFFIX}",
                    "placeholder": plain("Select a time")}
    if initial[0]:
        date_element["initial_date"] = initial[0]
    if initial[1]:
        time_element["initial_time"] = initial[1]
    blocks = [
        {"type": "section", "text": {"type": "mrkdwn", "text": f"*{label}*"}},
        {"type": "actions", "block_id": block_id, "elements": [date_element, time_element]},
    ]
    if error:
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": error}]})
    return blocks


def picked(values, block_id, date_action=None, time_action=None):
    row = values.get(block_id, {})
    return (row.get(date_action or f"{block_id}{DATE_SUFFIX}", {}).get("selected_date"),
            row.get(time_action or f"{block_id}{TIME_SUFFIX}", {}).get("selected_time"))


def duration(text):
    match = DURATION.match((text or "").strip())
    if not match:
        return None
    length = dt.timedelta(**{DURATION_UNITS[match.group(2).lower()]: int(match.group(1))})
    return length if MIN_DURATION <= length <= MAX_DURATION else None


def end_at(date_text, time_text, tz=dt.UTC):
    if not date_text:
        return None
    clock = dt.time.fromisoformat(time_text) if time_text else END_OF_DAY
    return dt.datetime.combine(dt.date.fromisoformat(date_text), clock, tz).astimezone(dt.UTC)


def end_error(date_text, time_text, at, required=False, now=None):
    if time_text and not date_text:
        return "Select a date for the end time."
    if required and not date_text:
        return "Select the end date."
    if at is None:
        return None
    if at <= (now or dt.datetime.now(dt.UTC)):
        return "Select a time in the future."
    return None


def ends(expires_at):
    return f"until {short_end(expires_at)}" if expires_at else "with no end date"


def logged_ends(expires_at):
    return f"until {short_end_token(expires_at)}" if expires_at else "with no end date"


def span(seconds):
    seconds = max(seconds, 0)
    if seconds >= 86400:
        return f"{seconds // 86400}d {seconds % 86400 // 3600}h"
    if seconds >= 3600:
        return f"{seconds // 3600}h {seconds % 3600 // 60}m"
    return f"{max(seconds // 60, 1)}m"


def remaining(expires_at, now=None):
    if not expires_at:
        return "with no end date"
    seconds = int((expires_at - (now or dt.datetime.now(dt.UTC))).total_seconds())
    return f"until {short_end(expires_at)} ({span(seconds)} left)"
