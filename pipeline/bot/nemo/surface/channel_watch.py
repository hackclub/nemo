import logging

from bot.core import session, whoami
from bot.nemo import channels
from bot.nemo.surface import on_event
from lib import channel_dim

log = logging.getLogger("bot.nemo")

FROM_TYPE = {"C": channel_dim.PUBLIC, "G": channel_dim.PRIVATE}


def look(client, channel_id, channel_type=None):
    seen = {"visibility": FROM_TYPE.get(channel_type)}
    try:
        found = (client.conversations_info(channel=channel_id) or {}).get("channel") or {}
    except Exception as failure:
        log.info("nemo: could not look %s up: %s", channel_id, failure)
        return seen
    return {
        "name": found.get("name"),
        "archived": found.get("is_archived"),
        "visibility": channel_dim.visibility_of(found) or seen["visibility"],
    }


@on_event("member_joined_channel", open_to_all=True)
def joined(ctx):
    event = ctx.payload or {}
    channel_id = event.get("channel")
    who = event.get("user")
    if not channel_id or not who:
        return None

    if who != whoami.bot_user_id(ctx.client, "nemo"):
        return None

    seen = look(ctx.client, channel_id, event.get("channel_type"))
    with session() as conn:
        fresh = not channels.inside(conn, channel_id)
        channels.sat(conn, channel_id, True)
        if fresh:
            channels.noted(conn, channel_id, "joined", by=event.get("inviter"))
        channel_dim.record(conn, channel_id, **seen)

    log.info("nemo: seated in %s (%s)", channel_id, seen.get("visibility") or "unknown")
    return channel_id


@on_event("member_left_channel", open_to_all=True)
def left(ctx):
    event = ctx.payload or {}
    channel_id = event.get("channel")
    who = event.get("user")
    if not channel_id or not who:
        return None

    if who != whoami.bot_user_id(ctx.client, "nemo"):
        return None

    with session() as conn:
        how = channels.mode(conn)
        wanted = channels.wanted(ctx.client, conn, how)
        channels.sat(conn, channel_id, False)
        if channel_id not in wanted:
            channels.noted(conn, channel_id, "left")
            log.info("nemo: left %s, which %s mode does not want back", channel_id, how)
            return None

    with session() as conn:
        came_back = channels.join(ctx.client, conn, channel_id, verb="rejoined")

    log.info("nemo: put out of %s, %s", channel_id,
             "went back in" if came_back else "could not get back in")
    return came_back


@on_event("channel_created", open_to_all=True)
def created(ctx):
    event = ctx.payload or {}
    made = event.get("channel") or {}
    if not isinstance(made, dict):
        made = {"id": made}
    channel_id = made.get("id")
    if not channel_id:
        return None

    archived = bool(made.get("is_archived"))
    with session() as conn:
        channel_dim.record(conn, channel_id, name=made.get("name"), archived=archived,
                           visibility=channel_dim.PUBLIC)

    if archived:
        return None

    with session() as conn:
        if channels.mode(conn) != channels.ON:
            return None
        return channels.join(ctx.client, conn, channel_id)
