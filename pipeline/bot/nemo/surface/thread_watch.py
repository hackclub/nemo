import logging

from bot.core import session
from bot.nemo import guards, guardwork
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

CARRIES = (None, "file_share", "me_message", "thread_broadcast")


@on_event("message", open_to_all=True)
def watched(ctx):
    event = ctx.payload or {}
    if event.get("subtype") not in CARRIES or event.get("bot_id"):
        return None

    channel_id = event.get("channel")
    thread_ts = event.get("thread_ts")
    ts = event.get("ts")
    if not channel_id or not ts:
        return None
    if not thread_ts:
        if guards.watching(channel_id, ts):
            log.info("nemo: %s posted at the top of guarded thread %s", event.get("user"), ts)
        return None
    if not guards.watching(channel_id, thread_ts):
        return None

    with session() as conn:
        guard = guards.held(conn, channel_id, thread_ts)
        if guard is None:
            guards.refresh(conn)
            return None
        who = event.get("user")
        if guards.exempt(conn, who, guard[5]):
            log.info("nemo: guard %s let %s past, they are exempt", guard[0], who)
            return None
        outcome = guardwork.took_it_further(ctx.client, conn, guard, who, ts)
        log.info("nemo: guard %s handled %s from %s -> %s", guard[0], ts, who, outcome)

    if outcome in ("reset", "would"):
        log.warning(
            "nemo: guard %s -> sessions %s for %s", guard[0], outcome, event.get("user")
        )
    return outcome
