import logging

from bot.core import session
from bot.nemo import channelguards, guard_actions
from bot.nemo.enforcement import notify
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

KIND = channelguards.SLOWMODE

DELETED = "deleted"

IN_CHANNEL = (
    "Slow mode is on here, {left} to go."
    "\n\nYour message was:\n{body}"
)

TICK = """
INSERT INTO fd.slowmode_clock (channel_id, thread_ts, user_id, posted_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (channel_id, thread_ts, user_id) DO UPDATE SET posted_at = now()
WHERE fd.slowmode_clock.posted_at <= now() - make_interval(secs => %s)
RETURNING posted_at
"""

SINCE = """
SELECT ceil(extract(epoch FROM (posted_at + make_interval(secs => %s)) - now()))::int
FROM fd.slowmode_clock
WHERE channel_id = %s AND thread_ts = %s AND user_id = %s
"""


def scope(standing, event):
    thread_ts = event.get("thread_ts")
    if not thread_ts:
        return ""
    return thread_ts if standing.threads() else None


def record_post(conn, channel_id, thread_ts, user_id, seconds):
    return conn.execute(TICK, (channel_id, thread_ts, user_id, seconds)).fetchone()


def left_to_go(conn, channel_id, thread_ts, user_id, seconds):
    row = conn.execute(SINCE, (seconds, channel_id, thread_ts, user_id)).fetchone()
    return max(1, row[0]) if row and row[0] else 1


def time_left(seconds):
    if seconds < 60:
        return f"{seconds} second{'' if seconds == 1 else 's'}"
    minutes = (seconds + 59) // 60
    return f"{minutes} minute{'' if minutes == 1 else 's'}"


@on_event("message", open_to_all=True)
def seen(ctx):
    event = ctx.payload or {}
    channel_id, subject_id, ts = notify.ours(event)
    if not channel_id:
        return None

    standing = channelguards.guarding(channel_id, KIND)
    if standing is None or standing.lets_past(subject_id):
        return None

    seconds = standing.seconds()
    if seconds <= 0:
        return None

    thread_ts = scope(standing, event)
    if thread_ts is None:
        return None

    with session() as conn:
        if record_post(conn, channel_id, thread_ts, subject_id, seconds):
            return None
        left = left_to_go(conn, channel_id, thread_ts, subject_id, seconds)

    body = event.get("text") or ""
    try:
        guard_actions.remove(ctx.client, channel_id, ts)
    except Exception as failure:
        log.warning("nemo: slow mode %s could not remove %s in %s: %s",
                    standing.guard_id, ts, channel_id, failure)
        return None

    with session() as conn:
        channelguards.record_enforcement(conn, standing.guard_id, channel_id, subject_id,
                               DELETED, text=body, message_ts=ts)

    notify.post_ephemeral(ctx.client, channel_id, subject_id,
                     IN_CHANNEL.format(left=time_left(left), body=body))
    log.info("nemo: slow mode %s removed %s from %s", standing.guard_id, ts, channel_id)
    return True
