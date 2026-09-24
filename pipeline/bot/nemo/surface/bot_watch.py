import datetime as dt
import logging
import os

from bot.core import privileged, session, whoami
from bot.core.wording import escape
from bot.nemo import channel, channelguards, channels
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

CARRIES = (None, "bot_message", "file_share", "thread_broadcast")
TELL_AGAIN_AFTER = dt.timedelta(hours=1)
MARKETPLACE = "https://hackclub.slack.com/marketplace"
QUOTE_LIMIT = 1200
CUT = "\n[truncated]"

_apps = {}


def ours():
    said = os.environ.get("EXEMPT_BOT_IDS", "")
    return {one.strip() for one in said.split(",") if one.strip()}


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


def words_of(event):
    said = (event.get("text") or "").strip()
    if said:
        return said

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
    parts = [f"<{url}|{said}>" for url, said in shown if url]
    return "\n" + "  ·  ".join(parts) if parts else ""


def permalink_for(client, channel_id, ts):
    try:
        return (client.chat_getPermalink(channel=channel_id, message_ts=ts) or {}).get("permalink")
    except Exception:
        return None


def tell(client, conn, guard_id, subject_id, said):
    held = channelguards.told_lately(conn, guard_id, subject_id)
    try:
        sent = client.chat_postMessage(
            channel=channel.firehouse_channel(conn), text=said,
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
    face_id = next((one for one in ids if one and one.startswith("U")), None)
    subject_id = face_id or bot_id or user_id
    said_words = words_of(event)
    link = permalink_for(ctx.client, channel_id, ts)
    privileged.delete_message(channel_id, ts)

    with session() as conn:
        said = (f"Deleted a message from {naming(face_id, label, subject_id)}, "
                f"which is not on the allow list for <#{channel_id}>."
                + quoted(said_words) + footer(channel_id, link, app_id))
        told_ts, told_until = tell(ctx.client, conn, guard_id, subject_id, said)
        channelguards.happened(conn, guard_id, channel_id, subject_id, "deleted",
                               bot_id=bot_id, label=label, said=said_words, message_ts=ts,
                               permalink=link, app_id=app_id,
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
    app_id = (found.get("profile") or {}).get("api_app_id")
    outcome = privileged.kick(channel_id, who)

    with session() as conn:
        said = (f"Put <@{who}> out of <#{channel_id}>, which is not on its "
                f"allow list." if outcome == "kicked" else
                f":warning: <@{who}> joined <#{channel_id}> off the allow list, and we "
                f"could not put them out ({outcome}).") + footer(channel_id, app_id=app_id)
        told_ts, told_until = tell(ctx.client, conn, guard_id, who, said)
        channelguards.happened(conn, guard_id, channel_id, who,
                               "kicked" if outcome == "kicked" else "let_past",
                               bot_id=(found.get("profile") or {}).get("bot_id"), label=label,
                               app_id=app_id,
                               told_ts=told_ts, told_until=told_until)

    log.info("nemo: guard %s met %s joining %s -> %s", guard_id, who, channel_id, outcome)
    return guard_id
