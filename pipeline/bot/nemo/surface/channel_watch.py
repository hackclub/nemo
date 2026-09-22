import logging

from bot.core import session, whoami
from bot.nemo import channels
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")


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
    channel_id = made.get("id") if isinstance(made, dict) else made
    if not channel_id or (isinstance(made, dict) and made.get("is_archived")):
        return None

    with session() as conn:
        if channels.mode(conn) != channels.ON:
            return None
        return channels.join(ctx.client, conn, channel_id)
