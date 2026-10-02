import logging

from bot.core import session
from bot.nemo import channel, guardwork, memberguards
from bot.nemo.carriers import carrying
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

KIND = memberguards.SHUSH

DELETED = "deleted"

TOLD = "Hey <@{who}>, you've been shushed for {why}, {until}."

IN_CHANNEL = (
    "Your message was removed. You are shushed for {why}, {until}. "
    "Replying here will not reach anybody."
)

OVER = "Your shush has ended. You can post again."


def take_up(client, conn, guard):
    if not memberguards.holding(conn, guard["id"]):
        return False

    carrying.tell_them(client, conn, guard, TOLD.format(
        who=guard["subject_id"], why=guard["reason"], until=carrying.ending(guard),
    ))
    log.info("nemo: shush %s is now held on %s", guard["id"], guard["subject_id"])
    return True


def let_go(client, conn, guard, tell=True):
    if tell:
        carrying.tell_them(client, conn, guard, OVER)
    return True


def remove(client, conn, guard, channel_id, ts):
    try:
        guardwork.remove(client, channel_id, ts)
    except Exception as failure:
        memberguards.dropped(conn, guard["id"], str(failure))
        memberguards.happened(conn, guard["id"], guard["subject_id"], channel_id,
                              "failed", message_ts=ts, detail=str(failure)[:500])
        log.warning("nemo: shush %s could not remove %s in %s: %s",
                    guard["id"], ts, channel_id, failure)
        return False

    memberguards.holding(conn, guard["id"])
    memberguards.happened(conn, guard["id"], guard["subject_id"], channel_id,
                          DELETED, message_ts=ts)
    return True


@on_event("message", open_to_all=True)
def seen(ctx):
    channel_id, subject_id, ts = carrying.ours(ctx.payload or {})
    if not channel_id:
        return None
    if channel_id == channel.firehouse_channel():
        return None

    guard = memberguards.shushed(subject_id)
    if guard is None:
        return None

    with session() as conn:
        if not remove(ctx.client, conn, guard, channel_id, ts):
            return None
        carrying.whisper(ctx.client, channel_id, subject_id, IN_CHANNEL.format(
            why=guard["reason"], until=carrying.ending(guard)))
        if carrying.earned_a_reset(conn, guard, DELETED):
            carrying.reset(conn, guard, "posting")
    return True
