import datetime as dt
import logging
import os

from bot.core import privileged, session, whoami
from bot.nemo import channel, channelguards
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

CARRIES = (None, "bot_message", "file_share", "thread_broadcast")
TELL_AGAIN_AFTER = dt.timedelta(hours=1)

_apps = {}


def ours():
    said = os.environ.get("EXEMPT_BOT_IDS", "")
    return {one.strip() for one in said.split(",") if one.strip()}


def bot_face(client, bot_id):
    if bot_id not in _apps:
        try:
            found = (client.bots_info(bot=bot_id) or {}).get("bot") or {}
        except Exception:
            found = {}
        _apps[bot_id] = (found.get("user_id"), found.get("name"), found.get("app_id"))
    return _apps[bot_id]


def who_posted(event):
    if event.get("subtype") not in CARRIES:
        return None, None
    bot_id = event.get("bot_id")
    if not bot_id and not (event.get("bot_profile") or event.get("subtype") == "bot_message"):
        return None, None
    return bot_id, event.get("user")


def names_for(client, bot_id, user_id):
    face_id = label = app_id = None
    if bot_id:
        face_id, label, app_id = bot_face(client, bot_id)
    return [one for one in (user_id, bot_id, face_id) if one], label, app_id


def permalink_for(client, channel_id, ts):
    try:
        return (client.chat_getPermalink(channel=channel_id, message_ts=ts) or {}).get("permalink")
    except Exception:
        return None


def tell(client, conn, guard_id, subject_id, said):
    held = channelguards.told_lately(conn, guard_id, subject_id)
    try:
        sent = client.chat_postMessage(
            channel=channel.firehouse_channel(), text=said,
            thread_ts=held, unfurl_links=False,
        )
    except Exception as failure:
        log.warning("nemo: could not say what the guard did: %s", failure)
        return None, None

    if held:
        return held, dt.datetime.now(dt.UTC) + TELL_AGAIN_AFTER
    return sent.get("ts"), dt.datetime.now(dt.UTC) + TELL_AGAIN_AFTER


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

    ids, label, app_id = names_for(ctx.client, bot_id, user_id)
    if not ids:
        return None
    if set(ids) & (ours() | {whoami.bot_user_id(ctx.client, "nemo")}):
        return None
    if channelguards.lets_past(channel_id, *ids):
        return None

    guard_id, _allowed = standing
    subject_id = bot_id or user_id
    privileged.delete_message(channel_id, ts)
    link = permalink_for(ctx.client, channel_id, ts)

    with session() as conn:
        said = (f":no_entry: Deleted a message from *{label or subject_id}*, which is not on "
                f"the allow list for <#{channel_id}>." + (f"\n{link}" if link else ""))
        told_ts, told_until = tell(ctx.client, conn, guard_id, subject_id, said)
        channelguards.happened(conn, guard_id, channel_id, subject_id, "deleted",
                               message_ts=ts, permalink=link, app_id=app_id,
                               told_ts=told_ts, told_until=told_until)

    log.info("nemo: guard %s deleted %s from %s in %s", guard_id, ts, subject_id, channel_id)
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
    outcome = privileged.kick(channel_id, who)

    with session() as conn:
        said = (f":no_entry: Put *{label}* out of <#{channel_id}>, which is not on its "
                f"allow list." if outcome == "kicked" else
                f":warning: *{label}* joined <#{channel_id}> off the allow list, and we "
                f"could not put them out ({outcome}).")
        told_ts, told_until = tell(ctx.client, conn, guard_id, who, said)
        channelguards.happened(conn, guard_id, channel_id, who,
                               "kicked" if outcome == "kicked" else "let_past",
                               app_id=(found.get("profile") or {}).get("api_app_id"),
                               told_ts=told_ts, told_until=told_until)

    log.info("nemo: guard %s met %s joining %s -> %s", guard_id, who, channel_id, outcome)
    return guard_id
