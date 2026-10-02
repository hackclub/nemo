import logging

from bot.core import session
from bot.nemo import channelguards, guardwork
from bot.nemo.carriers import carrying
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

KIND = channelguards.ACCOUNT_AGE

DELETED = "deleted"

IN_CHANNEL = (
    "This channel asks for an account {days} day{plural} old. Yours has {left} to go."
    "\n\nYour message was:\n{said}"
)

KEEP = """
INSERT INTO fd.member_joins (user_id, joined_at, source)
VALUES (%s, now(), 'team_join')
ON CONFLICT (user_id) DO NOTHING
RETURNING user_id
"""

DAYS_LEFT = """
SELECT ceil(extract(epoch FROM (known.at + make_interval(days => %s)) - now()) / 86400)::int
FROM (
    SELECT coalesce(j.joined_at, m.claimed_at) AS at
    FROM (SELECT %s::text AS user_id) asked
    LEFT JOIN fd.member_joins j ON j.user_id = asked.user_id
    LEFT JOIN analytics.dim_member m ON m.user_id = asked.user_id
) known
WHERE known.at IS NOT NULL
"""


def joined(conn, user_id):
    return conn.execute(KEEP, (user_id,)).fetchone()


def days_left(conn, user_id, days):
    row = conn.execute(DAYS_LEFT, (days, user_id)).fetchone()
    if row is None:
        return None
    return row[0] if row[0] and row[0] > 0 else None


@on_event("team_join", open_to_all=True)
def arrived(ctx):
    who = ((ctx.payload or {}).get("user") or {})
    user_id = who.get("id") if isinstance(who, dict) else who
    if not user_id:
        return None

    with session() as conn:
        if joined(conn, user_id):
            log.info("nemo: %s joined the workspace", user_id)
    return user_id


@on_event("message", open_to_all=True)
def seen(ctx):
    event = ctx.payload or {}
    channel_id, subject_id, ts = carrying.ours(event)
    if not channel_id:
        return None

    standing = channelguards.guarding(channel_id, KIND)
    if standing is None or standing.lets_past(subject_id):
        return None

    days = standing.min_age_days()
    if days <= 0:
        return None

    with session() as conn:
        left = days_left(conn, subject_id, days)
    if left is None:
        return None

    said = event.get("text") or ""
    try:
        guardwork.remove(ctx.client, channel_id, ts)
    except Exception as failure:
        log.warning("nemo: account age %s could not remove %s in %s: %s",
                    standing.guard_id, ts, channel_id, failure)
        return None

    with session() as conn:
        channelguards.happened(conn, standing.guard_id, channel_id, subject_id,
                               DELETED, said=said, message_ts=ts)

    carrying.whisper(ctx.client, channel_id, subject_id, IN_CHANNEL.format(
        days=days, plural="" if days == 1 else "s",
        left=f"{left} day{'' if left == 1 else 's'}", said=said))
    log.info("nemo: account age %s removed %s from %s", standing.guard_id, ts, channel_id)
    return True
