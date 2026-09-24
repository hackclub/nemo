import logging

from bot.core import access, evidence, session, whoami
from bot.nemo import casework, channel, channels
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
        said = (found.get("messages") or [{}])[0]
    except Exception as failure:
        log.info("nemo: could not read the thread above %s: %s", ts, failure)
        return ts, {}
    return said.get("thread_ts") or said.get("ts") or ts, said


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

    thread_ts, said = root_of(ctx.client, channel_id, ts)
    return channel_id, thread_ts, said, who


@on_event("reaction_added", open_to_all=True)
def opened(ctx):
    asked = wanted(ctx, OPENS, "case.open")
    if asked is None:
        return None
    channel_id, thread_ts, said, who = asked

    author = said.get("user")
    if not author:
        log.info("nemo: %s in %s has nobody to open a case about", thread_ts, channel_id)
        return None

    with session() as conn:
        standing = evidence.case_on(conn, channel_id, thread_ts)
        if standing is not None:
            log.info("nemo: %s in %s is already case %s", thread_ts, channel_id, standing)
            return standing

        body = (said.get("text") or "").strip() or None
        case_id = casework.open_case(conn, author, None, who)
        casework.open_report(conn, case_id, who, body)
        evidence.attach(conn, case_id,
                        {"channel_id": channel_id, "thread_ts": thread_ts}, who)
        channel.post_report(ctx.client, conn, case_id,
                            channel_id=channel_id, thread_ts=thread_ts)

    log.info("nemo: case %s opened on %s in %s by %s", case_id, thread_ts, channel_id, who)
    return case_id


@on_event("reaction_added", open_to_all=True)
def closed(ctx):
    asked = wanted(ctx, CLOSES, "case.resolve")
    if asked is None:
        return None
    channel_id, thread_ts, _, who = asked

    with session() as conn:
        case_id = evidence.case_on(conn, channel_id, thread_ts)
        if case_id is None:
            return None

        told = casework.resolve(
            conn, case_id,
            {"resolution": CLOSED_AS, "member_note": None, "said": None, "telling": False},
            who,
        )
        if told is None:
            log.info("nemo: case %s was already resolved", case_id)
            return None
        channel.redraw(ctx.client, conn, case_id, channel_id)

    log.info("nemo: case %s resolved from the thread by %s", case_id, who)
    return case_id
