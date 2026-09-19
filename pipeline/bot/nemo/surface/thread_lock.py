import datetime as dt
import logging

from bot.core import session
from bot.nemo import guards
from bot.nemo.cards import guard as card
from bot.nemo.surface import on_shortcut, on_view

log = logging.getLogger("bot.nemo")

SHORTCUT = "lock_thread"


@on_shortcut(SHORTCUT, needs="thread.guard")
def asked(ctx):
    if not ctx.thread_ts:
        return ctx.whisper("that is not a thread")

    ctx.join()
    ctx.client.views_open(
        trigger_id=ctx.trigger_id,
        view=card.lock_view(ctx.channel_id, ctx.thread_ts),
    )


@on_view(card.LOCK_CALLBACK, needs="thread.guard", refuse_block=card.REASON)
def confirmed(ctx):
    said = card.picked(ctx.view.get("state") or {})
    wrong = card.objection(said, needs_until=True)
    if wrong:
        return ctx.ack(response_action="errors", errors=wrong)

    lifts = dt.datetime.fromtimestamp(said["until"], dt.UTC)
    if lifts <= dt.datetime.now(dt.UTC):
        return ctx.ack(response_action="errors", errors={card.UNTIL: "That is in the past."})

    ctx.ack()
    channel_id, thread_ts = card.opened(ctx.view)
    if not channel_id or not thread_ts:
        return None

    with session() as conn:
        guard_id = guards.open_guard(
            conn, guards.LOCK, channel_id, thread_ts, ctx.user_id, said["reason"],
            expires_at=lifts,
        )

    if guard_id is None:
        return ctx.whisper("that thread is already held", channel_id, thread_ts)

    with session() as conn:
        guards.warn(ctx.client, conn, guard_id, channel_id, thread_ts, guards.LOCK)
        guards.refresh(conn)

    log.info("nemo: %s locked %s until %s (guard %s)", ctx.user_id, thread_ts, lifts, guard_id)
    return guard_id
