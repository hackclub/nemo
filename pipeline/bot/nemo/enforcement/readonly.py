import logging

from bot.core import session
from bot.nemo import channelguards, guard_actions
from bot.nemo.enforcement import notify
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

KIND = channelguards.READONLY

DELETED = "deleted"

IN_CHANNEL = (
    "This channel is read-only. Reply in a thread if you are answering somebody."
    "\n\nYour message was:\n{body}"
)


def in_a_thread(event):
    thread_ts = event.get("thread_ts")
    return bool(thread_ts) and event.get("subtype") != "thread_broadcast"


@on_event("message", open_to_all=True)
def seen(ctx):
    event = ctx.payload or {}
    channel_id, subject_id, ts = notify.ours(event)
    if not channel_id:
        return None

    standing = channelguards.guarding(channel_id, KIND)
    if standing is None or standing.lets_past(subject_id):
        return None
    if in_a_thread(event) and not standing.threads():
        return None

    body = event.get("text") or ""
    try:
        guard_actions.remove(ctx.client, channel_id, ts)
    except Exception as failure:
        log.warning("nemo: read-only %s could not remove %s in %s: %s",
                    standing.guard_id, ts, channel_id, failure)
        return None

    with session() as conn:
        channelguards.record_enforcement(conn, standing.guard_id, channel_id, subject_id,
                               DELETED, text=body, message_ts=ts)

    notify.post_ephemeral(ctx.client, channel_id, subject_id, IN_CHANNEL.format(body=body),
                     thread_ts=event.get("thread_ts"))
    log.info("nemo: read-only %s removed %s from %s", standing.guard_id, ts, channel_id)
    return True
