import logging

from bot.core import session
from bot.nemo import channel, guard_actions, memberguards
from bot.nemo.enforcement import notify
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

    notify.dm_subject(client, conn, guard, TOLD.format(
        who=guard["subject_id"], why=guard["reason"], until=notify.ending(guard),
    ))
    log.info("nemo: shush %s is now held on %s", guard["id"], guard["subject_id"])
    return True


def lift(client, conn, guard, tell=True):
    if tell:
        notify.dm_subject(client, conn, guard, OVER)
    return True


def remove(client, conn, guard, channel_id, ts):
    try:
        guard_actions.remove(client, channel_id, ts)
    except Exception as failure:
        memberguards.dropped(conn, guard["id"], str(failure))
        memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], channel_id,
                              "failed", message_ts=ts, detail=str(failure)[:500])
        log.warning("nemo: shush %s could not remove %s in %s: %s",
                    guard["id"], ts, channel_id, failure)
        return False

    memberguards.holding(conn, guard["id"])
    memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], channel_id,
                          DELETED, message_ts=ts)
    return True


@on_event("message", open_to_all=True)
def seen(ctx):
    channel_id, subject_id, ts = notify.ours(ctx.payload or {})
    if not channel_id:
        return None
    if channel_id == channel.internal_log_channel():
        return None

    guard = memberguards.shushed(subject_id)
    if guard is None:
        return None

    with session() as conn:
        if not remove(ctx.client, conn, guard, channel_id, ts):
            return None
        notify.post_ephemeral(ctx.client, channel_id, subject_id, IN_CHANNEL.format(
            why=guard["reason"], until=notify.ending(guard)))
        if notify.reset_threshold_met(conn, guard, DELETED):
            notify.reset(conn, guard, "posting")
    return True
