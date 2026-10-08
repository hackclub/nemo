import datetime as dt
import logging
import os
import time

from bot.core import privileged, session, whoami
from bot.core.formatting import escape
from bot.nemo import channel, channelguards, channels
from bot.nemo.surface import on_event
from bot.nemo.views.activity import message_url

log = logging.getLogger("bot.nemo")

CARRIES = (None, "bot_message", "file_share", "thread_broadcast")
NOTICE_IDLE_TIMEOUT = dt.timedelta(hours=1)
NOTICE_MAX_AGE = dt.timedelta(hours=24)
MARKETPLACE = "https://hackclub.slack.com/marketplace"
QUOTE_LIMIT = 1200
CUT = "\n[truncated]"

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


def naming(face_id, label, fallback):
    if face_id:
        return f"<@{face_id}>"
    return f"*{label or fallback}*"


def quoted(words):
    text = (words or "").strip()
    if not text:
        return ""
    if len(text) > QUOTE_LIMIT:
        text = text[:QUOTE_LIMIT].rstrip() + CUT
    return "\n" + "\n".join(f"> {line}" for line in escape(text).splitlines())


def marketplace_url(app_id):
    return f"{MARKETPLACE}/{app_id}" if app_id else None


def footer(channel_id, link=None, app_id=None):
    shown = (
        (link, "message link"),
        (marketplace_url(app_id), "marketplace"),
        (channel.channel_url(channel_id), "open in fire engine"),
    )
    parts = [f"<{url}|{name}>" for url, name in shown if url]
    return "\n" + "  ·  ".join(parts) if parts else ""


def plural(count, one, many):
    return f"{count} {one if count == 1 else many}"


def summary(name, channel_id, deleted, kicked):
    parts = [f"{name} is not on the allow list for <#{channel_id}>."]
    if deleted:
        parts.append(f"Deleted {plural(deleted, 'message', 'messages')}.")
    if kicked:
        parts.append(f"Removed from the channel {plural(kicked, 'time', 'times')}.")
    return " ".join(parts)


def post_notice(client, conn, guard_id, channel_id, subject_id, name, verb, detail):
    deleted = 1 if verb == "deleted" else 0
    kicked = 1 if verb == "kicked" else 0
    log_channel = channel.internal_log_channel(conn)
    channelguards.lock_notice_thread(conn, guard_id, subject_id)
    thread = channelguards.open_notice_thread(conn, guard_id, subject_id,
                                              NOTICE_IDLE_TIMEOUT, NOTICE_MAX_AGE)

    if thread is None:
        try:
            sent = client.chat_postMessage(
                channel=log_channel, text=summary(name, channel_id, deleted, kicked),
                unfurl_links=False,
            )
        except Exception as failure:
            log.warning("nemo: could not open a notice thread for guard %s: %s", guard_id, failure)
            return None
        parent_ts = sent.get("ts")
        channelguards.open_new_notice_thread(conn, guard_id, subject_id, parent_ts, deleted, kicked)
        totals = None
    else:
        thread_id, parent_ts = thread
        totals = channelguards.note_event(conn, thread_id, deleted, kicked)

    try:
        client.chat_postMessage(channel=log_channel, text=detail, thread_ts=parent_ts,
                                unfurl_links=False)
    except Exception as failure:
        log.warning("nemo: could not reply in notice thread %s: %s", parent_ts, failure)

    if totals is not None:
        try:
            client.chat_update(channel=log_channel, ts=parent_ts,
                               text=summary(name, channel_id, *totals))
        except Exception as failure:
            log.warning("nemo: could not update notice thread %s: %s", parent_ts, failure)

    return parent_ts


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
    privileged.delete_message(channel_id, ts)
    took_ms = round((time.time() - float(ts)) * 1000)
    words = text_of(event)
    link = message_url(channel_id, ts, event.get("thread_ts"))

    with session() as conn:
        name = naming(face_id, label, subject_id)
        notice = (f"Deleted a message from {name}, "
                f"which is not on the allow list for <#{channel_id}>."
                + quoted(words) + footer(channel_id, link, app_id))
        post_notice(ctx.client, conn, guard_id, channel_id, subject_id, name, "deleted", notice)
        channelguards.record_enforcement(conn, guard_id, channel_id, subject_id, "deleted",
                               bot_id=bot_id, label=label, text=words, message_ts=ts,
                               permalink=link, app_id=app_id)

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
        notice = (f"Put <@{who}> out of <#{channel_id}>, which is not on its "
                f"allow list." if outcome == "kicked" else
                f":warning: <@{who}> joined <#{channel_id}> off the allow list, and we "
                f"could not put them out ({outcome}).") + footer(channel_id, app_id=app_id)
        post_notice(ctx.client, conn, guard_id, channel_id, who, f"<@{who}>", verb, notice)
        channelguards.record_enforcement(conn, guard_id, channel_id, who, verb,
                               bot_id=(found.get("profile") or {}).get("bot_id"), label=label,
                               app_id=app_id)

    log.info("nemo: guard %s met %s joining %s -> %s", guard_id, who, channel_id, outcome)
    return guard_id
