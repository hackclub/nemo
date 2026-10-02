import logging

from bot.core import session
from bot.nemo import channelguards, guardwork
from bot.nemo.carriers import carrying
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

KIND = channelguards.READONLY

DELETED = "deleted"

IN_CHANNEL = (
    "This channel is read-only. Reply in a thread if you are answering somebody."
    "\n\nYour message was:\n{said}"
)


def in_a_thread(event):
    thread_ts = event.get("thread_ts")
    return bool(thread_ts) and event.get("subtype") != "thread_broadcast"


@on_event("message", open_to_all=True)
def seen(ctx):
    event = ctx.payload or {}
    channel_id, subject_id, ts = carrying.ours(event)
    if not channel_id or in_a_thread(event):
        return None

    standing = channelguards.guarding(channel_id, KIND)
    if standing is None or standing.lets_past(subject_id):
        return None

    said = event.get("text") or ""
    try:
        guardwork.remove(ctx.client, channel_id, ts)
    except Exception as failure:
        log.warning("nemo: read-only %s could not remove %s in %s: %s",
                    standing.guard_id, ts, channel_id, failure)
        return None

    with session() as conn:
        channelguards.happened(conn, standing.guard_id, channel_id, subject_id,
                               DELETED, said=said, message_ts=ts)

    carrying.whisper(ctx.client, channel_id, subject_id, IN_CHANNEL.format(said=said))
    log.info("nemo: read-only %s removed %s from %s", standing.guard_id, ts, channel_id)
    return True
