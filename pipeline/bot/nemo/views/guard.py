import datetime as dt
import json

from bot.core import richtext
from bot.nemo.views import lengths, removal

DESTROY_CALLBACK = "thread_destroy"
LOCK_CALLBACK = "thread_lock"
UNLOCKED_CALLBACK = "thread_unlocked"

REASON = "guard_reason"
NOTE = "guard_note"
NOTE_TEXT = "guard_note_text"
END = "lock_end"
UNLOCK = "lock_off"
NOTICE_MENU = "lock_notice_menu"
NOTICE_UNLOCK = "unlock"
LOCK_TITLE = "Lock thread"
UNLOCK_TITLE = "Unlock thread"

REASON_LIMIT = 500
NOTE_LABEL = "Post note in thread"
TITLE_LIMIT = 24

SIGN_OUT_NOTE = "Sign-out on repeated posts"


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


def reason_block(value=None):
    element = {
        "type": "plain_text_input",
        "action_id": REASON,
        "multiline": True,
        "max_length": REASON_LIMIT,
    }
    if value:
        element["initial_value"] = value
    return {
        "type": "input",
        "block_id": REASON,
        "label": {"type": "plain_text", "text": "Reason"},
        "element": element,
    }


def note_option():
    return {"text": {"type": "mrkdwn", "text": NOTE_LABEL}, "value": "on"}


def note_block(on):
    element = {"type": "checkboxes", "action_id": NOTE, "options": [note_option()]}
    if on:
        element["initial_options"] = [note_option()]
    return {
        "type": "input",
        "block_id": NOTE,
        "optional": True,
        "dispatch_action": True,
        "label": {"type": "plain_text", "text": "Note"},
        "element": element,
    }


def note_text_block(value=None):
    element = {
        "type": "rich_text_input",
        "action_id": NOTE_TEXT,
        "min_lines": 4,
    }
    if value:
        element["initial_value"] = value
    return {
        "type": "input",
        "block_id": NOTE_TEXT,
        "label": {"type": "plain_text", "text": "Note text"},
        "element": element,
    }


def section_block(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}}


def context_block():
    return {"type": "context", "elements": [{"type": "mrkdwn", "text": SIGN_OUT_NOTE}]}


def destroy_view(channel_id, thread_ts, values=None):
    values = values or {}
    blocks = [
        context_block(),
        reason_block(values.get("reason")),
        note_block(values.get("note")),
    ]
    if values.get("note"):
        blocks.append(note_text_block(values.get("note_body")))

    return {
        "type": "modal",
        "callback_id": DESTROY_CALLBACK,
        "private_metadata": metadata(channel_id, thread_ts),
        "title": {"type": "plain_text", "text": "Destroy thread"[:TITLE_LIMIT]},
        "submit": {"type": "plain_text", "text": "Destroy"},
        "close": {"type": "plain_text", "text": "Cancel"},
        "blocks": blocks,
    }


def lock_modal(channel_id, thread_ts, submit, blocks, extend=False):
    return {
        "type": "modal",
        "callback_id": LOCK_CALLBACK,
        "private_metadata": metadata(channel_id, thread_ts, extend),
        "title": lengths.plain(LOCK_TITLE),
        "submit": lengths.plain(submit),
        "close": lengths.plain("Cancel"),
        "blocks": blocks,
    }


def lock_view(channel_id, thread_ts, values=None, end_error=None, tz=None):
    values = values or {}
    blocks = lengths.end_row(END, "End", (values.get("end_date"), values.get("end_time")), end_error,
                             tz=tz, optional=True)
    blocks.append(reason_block(values.get("reason")))
    return lock_modal(channel_id, thread_ts, "Lock", blocks)


def unlock_confirm():
    return {"title": lengths.plain(UNLOCK_TITLE),
            "text": {"type": "mrkdwn", "text": "Unlock this thread."},
            "confirm": lengths.plain("Unlock"), "deny": lengths.plain("Cancel"),
            "style": "danger"}


def lock_status_block(current, now=None):
    return {
        "type": "section",
        "text": {"type": "mrkdwn",
                 "text": f"*Locked* {lengths.remaining(current['expires_at'], now)} "
                         f"for *{current['reason']}*, set by <@{current['opened_by']}>"},
        "accessory": {
            "type": "button", "action_id": UNLOCK, "style": "danger", "text": lengths.plain("Unlock"),
            "confirm": unlock_confirm(),
        },
    }


def notice_menu():
    return {
        "type": "overflow",
        "action_id": NOTICE_MENU,
        "options": [{"text": lengths.plain(UNLOCK_TITLE), "value": NOTICE_UNLOCK}],
        "confirm": unlock_confirm(),
    }


def selected_option(body):
    actions = (body or {}).get("actions") or [{}]
    return (actions[0].get("selected_option") or {}).get("value")


def locked_view(channel_id, thread_ts, current, tz=dt.UTC, values=None, end_error=None, now=None):
    initial = lengths.initial_of(current["expires_at"], tz)
    if values and (values.get("end_date") or values.get("end_time")):
        initial = (values.get("end_date"), values.get("end_time"))
    blocks = [lock_status_block(current, now), *lengths.end_row(END, "New end", initial, end_error, tz=tz)]
    return lock_modal(channel_id, thread_ts, "Save", blocks, extend=True)


def unlocked_view():
    return {
        "type": "modal",
        "callback_id": UNLOCKED_CALLBACK,
        "title": lengths.plain(LOCK_TITLE),
        "close": lengths.plain("Close"),
        "blocks": [section_block("*Unlocked*")],
    }


def submitted_values(state, extending=False):
    values = state.get("values", {})
    checked_options = values.get(NOTE, {}).get(NOTE, {}).get("selected_options") or []
    end_date, end_time = lengths.picked(values, END)
    return {
        "reason": (values.get(REASON, {}).get(REASON, {}).get("value") or "").strip(),
        "starting": not extending,
        "end_date": end_date,
        "end_time": end_time,
        "note": bool(checked_options),
        "note_body": values.get(NOTE_TEXT, {}).get(NOTE_TEXT, {}).get("rich_text_value"),
    }


def note_text(values):
    return richtext.flatten(values.get("note_body")) if values.get("note") else ""


SIGNS_OUT = "Repeated replies sign you out of Slack"


def lock_notice(expires_at, reason, signs_out=False):
    text = f"*Thread locked* {lengths.ends(expires_at)} for *{reason}*"
    blocks = [{**section_block(text), "accessory": notice_menu()}]
    if signs_out:
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": SIGNS_OUT}]})
    return {"text": text, "blocks": blocks}


def lock_removal_notice(expires_at, body):
    text = f"*Thread locked* {lengths.ends(expires_at)}"
    return removal.notice(text, body)


def lock_end(values, tz=dt.UTC):
    return lengths.end_at(values["end_date"], values["end_time"], tz)


def lock_errors(values, tz=dt.UTC, now=None):
    if values["starting"] and not values["reason"]:
        return {REASON: "Add a reason."}
    message = lengths.end_error(
        values["end_date"], values["end_time"], lock_end(values, tz),
        required=not values["starting"], now=now,
    )
    return {END: message} if message else None


def validation_errors(values):
    if not values.get("reason"):
        return {REASON: "Add a reason."}
    if values.get("note") and not note_text(values):
        return {NOTE_TEXT: "Enter note text"}
    return None
