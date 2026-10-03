import logging

from bot.core import access, session, whoami
from bot.nemo import case_actions, channels, chat, case_queue
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

OPENS = ("hourglass", "hourglass_flowing_sand", "hourglass_not_done")
CLOSES = ("white_check_mark", "heavy_check_mark", "ballot_box_with_check")
CLOSED_AS = "no_action"


def plain(name):
    return (name or "").split("::")[0]


def root_of(client, channel_id, ts):
    try:
        found = client.conversations_replies(
            channel=channel_id, ts=ts, limit=1, inclusive=True
        )
        message = (found.get("messages") or [{}])[0]
    except Exception as failure:
        log.info("nemo: could not read the thread above %s: %s", ts, failure)
        return ts, {}
    return message.get("thread_ts") or message.get("ts") or ts, message


def wanted(ctx, marks, needs):
    event = ctx.payload or {}
    item = event.get("item") or {}
    if item.get("type") != "message":
        return None

    channel_id, ts = item.get("channel"), item.get("ts")
    who = event.get("user")
    if not channel_id or not ts or not who:
        return None
    if plain(event.get("reaction")) not in marks:
        return None
    if who == whoami.bot_user_id(ctx.client, "nemo"):
        return None

    with session() as conn:
        if channel_id not in channels.react_channels(conn):
            return None
        may, _why = access.may(conn, who, needs)
    if not may:
        log.info("nemo: %s reacted in %s without %s", who, channel_id, needs)
        return None

    thread_ts, message = root_of(ctx.client, channel_id, ts)
    return channel_id, thread_ts, message, who


def worth_keeping(message):
    return bool(
        message.get("ts") and message.get("user") and (message.get("text") or message.get("blocks"))
    )


def keep_the_root(conn, case_id, channel_id, message):
    if not worth_keeping(message):
        return None

    chat_id, _ = chat.keep(conn, case_id, dict(message, channel=channel_id))
    return chat_id


@on_event("reaction_added", open_to_all=True)
def opened(ctx):
    asked = wanted(ctx, OPENS, "case.open")
    if asked is None:
        return None
    channel_id, thread_ts, message, who = asked

    with session() as conn:
        standing = case_queue.case_on(conn, channel_id, thread_ts)
        if standing is not None:
            log.info("nemo: %s in %s is already case %s", thread_ts, channel_id, standing)
            return standing

        case_id = case_actions.open_case(conn, None, None, who)
        keep_the_root(conn, case_id, channel_id, message)
        case_queue.post(ctx.client, conn, case_id, channel_id, thread_ts)

    log.info("nemo: case %s opened on %s in %s by %s", case_id, thread_ts, channel_id, who)
    return case_id


@on_event("reaction_added", open_to_all=True)
def closed(ctx):
    asked = wanted(ctx, CLOSES, "case.resolve")
    if asked is None:
        return None
    channel_id, thread_ts, _, who = asked

    with session() as conn:
        case_id = case_queue.case_on(conn, channel_id, thread_ts)
        if case_id is None:
            return None

        told = case_actions.resolve(
            conn, case_id,
            {"resolution": CLOSED_AS, "member_note": None, "message": None, "telling": False},
            who,
        )
        if told is None:
            log.info("nemo: case %s was already resolved", case_id)
            return None
        case_queue.refresh_card(ctx.client, conn, case_id)

    log.info("nemo: case %s resolved from the thread by %s", case_id, who)
    return case_id
