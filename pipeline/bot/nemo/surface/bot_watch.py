import logging
import os
import time

from bot.core import privileged, session, whoami
from bot.nemo import channelguards, channels
from bot.nemo.surface import on_event
from bot.nemo.views.activity import message_url

log = logging.getLogger("bot.nemo")

CARRIES = (None, "bot_message", "file_share", "thread_broadcast")

_apps = {}
_people = {}


def ours():
    raw = os.environ.get("EXEMPT_BOT_IDS", "")
    return {one.strip() for one in raw.split(",") if one.strip()}


def ask_about(client, bot_id):
    where = channels.team()
    asked = {"bot": bot_id, "team_id": where} if where else {"bot": bot_id}
    try:
        return (client.bots_info(**asked) or {}).get("bot") or {}
    except Exception as failure:
        log.info("nemo: could not look up %s: %s", bot_id, failure)
        return {}


def bot_face(client, bot_id):
    if bot_id not in _apps:
        found = ask_about(client, bot_id)
        if not found:
            return None, None, None
        _apps[bot_id] = (found.get("user_id"), found.get("name"), found.get("app_id"))
    return _apps[bot_id]


def fetch_user(client, user_id):
    try:
        return (client.users_info(user=user_id) or {}).get("user") or {}
    except Exception as failure:
        log.info("nemo: could not look up %s: %s", user_id, failure)
        return {}


def get_user(client, user_id):
    if user_id not in _people:
        found = fetch_user(client, user_id)
        if not found:
            return {}
        _people[user_id] = found
    return _people[user_id]


def who_posted(event):
    if event.get("subtype") not in CARRIES:
        return None, None
    bot_id = event.get("bot_id")
    if not bot_id and not (event.get("bot_profile") or event.get("subtype") == "bot_message"):
        return None, None
    return bot_id, event.get("user")


def is_userbot(client, event, bot_id, user_id):
    if event.get("subtype") == "bot_message" or not user_id:
        return False
    face_id, _label, _app_id = bot_face(client, bot_id) if bot_id else (None, None, None)
    if user_id == face_id:
        return False
    return get_user(client, user_id).get("is_bot") is False


def names_for(client, bot_id, user_id):
    face_id = label = app_id = None
    if bot_id:
        face_id, label, app_id = bot_face(client, bot_id)
    return [one for one in (user_id, bot_id, face_id) if one], label, app_id


def text_of(event):
    text = (event.get("text") or "").strip()
    if text:
        return text

    for block in event.get("attachments") or []:
        fallen = (block.get("text") or block.get("fallback") or "").strip()
        if fallen:
            return fallen
    return None


@on_event("message", open_to_all=True)
def posted(ctx):
    event = ctx.payload or {}
    channel_id = event.get("channel")
    ts = event.get("ts")
    bot_id, user_id = who_posted(event)
    if not channel_id or not ts or not (bot_id or user_id):
        return None

    standing = channelguards.guarding(channel_id)
    if standing is None:
        return None

    if is_userbot(ctx.client, event, bot_id, user_id):
        log.info("nemo: %s posted in %s with a user token, not a bot", user_id, channel_id)
        return None

    ids, label, app_id = names_for(ctx.client, bot_id, user_id)
    if not ids:
        return None
    if set(ids) & (ours() | {whoami.bot_user_id(ctx.client, "nemo")}):
        return None
    if channelguards.lets_past(channel_id, *ids):
        return None

    guard_id, _allowed = standing
    face_id = next((one for one in ids if one and one.startswith("U")), None)
    subject_id = face_id or bot_id or user_id
    failure = None
    try:
        privileged.delete_message(channel_id, ts, max_retries=0)
    except Exception as failed:
        if not privileged.gone(failed):
            failure = failed
    took_ms = round((time.time() - float(ts)) * 1000)
    words = text_of(event)
    link = message_url(channel_id, ts, event.get("thread_ts"))

    with session() as conn:
        channelguards.record_enforcement(conn, guard_id, channel_id, subject_id, "deleted",
                               bot_id=bot_id, label=label, text=words, message_ts=ts,
                               permalink=link, app_id=app_id, notice_wanted=True,
                               detail=failure and str(failure)[:500],
                               remove_pending=failure is not None)

    if failure is not None:
        log.info("nemo: guard %s could not delete %s in %s yet, queued for a retry: %s",
                 guard_id, ts, channel_id, failure)
        return guard_id
    log.info("nemo: guard %s deleted %s from %s in %s, %sms after it was posted",
             guard_id, ts, subject_id, channel_id, took_ms)
    return guard_id


@on_event("member_joined_channel", open_to_all=True)
def joined(ctx):
    event = ctx.payload or {}
    channel_id = event.get("channel")
    who = event.get("user")
    if not channel_id or not who:
        return None

    standing = channelguards.guarding(channel_id)
    if standing is None:
        return None
    if who in (ours() | {whoami.bot_user_id(ctx.client, "nemo")}):
        return None

    try:
        found = (ctx.client.users_info(user=who) or {}).get("user") or {}
    except Exception:
        return None
    if not found.get("is_bot"):
        return None

    ids = [who, (found.get("profile") or {}).get("bot_id")]
    if channelguards.lets_past(channel_id, *[one for one in ids if one]):
        return None

    guard_id, _allowed = standing
    label = found.get("real_name") or who
    app_id = (found.get("profile") or {}).get("api_app_id")
    outcome = privileged.kick(channel_id, who)

    verb = "kicked" if outcome == "kicked" else "let_past"

    with session() as conn:
        channelguards.record_enforcement(conn, guard_id, channel_id, who, verb,
                               bot_id=(found.get("profile") or {}).get("bot_id"), label=label,
                               app_id=app_id, detail=None if verb == "kicked" else outcome,
                               notice_wanted=True)

    log.info("nemo: guard %s met %s joining %s -> %s", guard_id, who, channel_id, outcome)
    return guard_id
