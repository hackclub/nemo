import logging

from bot.core import privileged, session
from bot.nemo import guardwork, memberguards
from bot.nemo.carriers import carrying
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

KIND = memberguards.CHANNEL_BAN

KICKED = "kicked"

TOLD = "Hey <@{who}>, you've been banned from <#{room}> for {why}, {until}."

IN_CHANNEL = (
    "Your message was removed. You are banned from this channel for {why}, {until}."
)

OVER = "Your ban from <#{room}> has ended. You can join it again."


def put_out(conn, guard):
    how = privileged.kick(guard["channel_id"], guard["subject_id"])
    if how != KICKED:
        memberguards.dropped(conn, guard["id"], how)
        memberguards.happened(conn, guard["id"], guard["subject_id"], guard["channel_id"],
                              "failed", detail=how)
        log.warning("nemo: channel ban %s could not put %s out of %s: %s",
                    guard["id"], guard["subject_id"], guard["channel_id"], how)
        return False

    memberguards.holding(conn, guard["id"])
    memberguards.happened(conn, guard["id"], guard["subject_id"], guard["channel_id"], KICKED)
    return True


def take_up(client, conn, guard):
    if not put_out(conn, guard):
        return False

    carrying.tell_them(client, conn, guard, TOLD.format(
        who=guard["subject_id"], room=guard["channel_id"],
        why=guard["reason"], until=carrying.ending(guard),
    ))
    log.info("nemo: channel ban %s is now held on %s in %s",
             guard["id"], guard["subject_id"], guard["channel_id"])
    return True


def let_go(client, conn, guard, tell=True):
    if tell:
        carrying.tell_them(client, conn, guard, OVER.format(room=guard["channel_id"]))
    return True


def again(conn, guard, why):
    if not carrying.earned_a_reset(conn, guard, KICKED):
        return False

    carrying.reset(conn, guard, why)
    return True


@on_event("message", open_to_all=True)
def seen(ctx):
    channel_id, subject_id, ts = carrying.ours(ctx.payload or {})
    if not channel_id:
        return None

    guard = memberguards.banned(subject_id, channel_id)
    if guard is None:
        return None

    with session() as conn:
        try:
            guardwork.remove(ctx.client, channel_id, ts)
        except Exception as failure:
            memberguards.dropped(conn, guard["id"], str(failure))
            memberguards.happened(conn, guard["id"], subject_id, channel_id,
                                  "failed", message_ts=ts, detail=str(failure)[:500])
            return None

        memberguards.happened(conn, guard["id"], subject_id, channel_id,
                              "deleted", message_ts=ts)
        carrying.whisper(ctx.client, channel_id, subject_id, IN_CHANNEL.format(
            why=guard["reason"], until=carrying.ending(guard)))
        put_out(conn, guard)
        again(conn, guard, "posting")
    return True


@on_event("member_joined_channel", open_to_all=True)
def joined(ctx):
    event = ctx.payload or {}
    channel_id = event.get("channel")
    subject_id = event.get("user")
    if not channel_id or not subject_id:
        return None

    guard = memberguards.banned(subject_id, channel_id)
    if guard is None:
        return None

    with session() as conn:
        put_out(conn, guard)
        again(conn, guard, "coming back")
    log.info("nemo: %s came back to %s under channel ban %s",
             subject_id, channel_id, guard["id"])
    return True
