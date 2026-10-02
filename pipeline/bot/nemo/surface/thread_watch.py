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

    who = event.get("user")
    with session() as conn:
        guard = guards.held(conn, channel_id, thread_ts)
        if guard is None:
            guards.refresh(conn)
            return None
        if guards.exempt(conn, who, guard[5]):
            log.info("nemo: guard %s let %s past, they are exempt", guard[0], who)
            return None
        noted = guardwork.note_it(conn, guard, who, ts)

    if not noted:
        return None

    guardwork.took_it_down(ctx.client, guard[0], channel_id, ts)
    log.info("nemo: guard %s noted %s from %s", guard[0], ts, who)
    return guardwork.earned_it(guard, who) or "noted"
