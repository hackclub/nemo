import logging

from bot.core import session
from bot.nemo import guards
from bot.nemo.cards import guard as card
from bot.nemo.surface import on_action, on_shortcut, on_view

log = logging.getLogger("bot.nemo")

SHORTCUT = "destroy_thread"


@on_shortcut(SHORTCUT, needs="thread.guard")
def asked(ctx):
    if not ctx.thread_ts:
        return ctx.whisper("that is not a thread")

    ctx.client.views_open(
        trigger_id=ctx.trigger_id,
        view=card.destroy_view(ctx.channel_id, ctx.thread_ts),
    )


@on_action(card.NOTE, needs="thread.guard")
def note_toggled(ctx):
    view = ctx.view
    if view.get("callback_id") != card.DESTROY_CALLBACK:
        return None

    channel_id, thread_ts = card.opened(view)
    said = card.picked(view.get("state") or {})
    try:
        ctx.client.views_update(
            view_id=view["id"],
            hash=view["hash"],
            view=card.destroy_view(channel_id, thread_ts, said=said),
        )
    except Exception as failure:
        log.warning("nemo: could not reshape the destroy modal: %s", failure)
    return None


@on_view(card.DESTROY_CALLBACK, needs="thread.guard", refuse_block=card.REASON)
def confirmed(ctx):
    said = card.picked(ctx.view.get("state") or {})
    wrong = card.objection(said)
    if wrong:
        return ctx.ack(response_action="errors", errors=wrong)

    ctx.ack()
    channel_id, thread_ts = card.opened(ctx.view)
    if not channel_id or not thread_ts:
        return None

    with session() as conn:
        guard_id = guards.open_guard(
            conn, guards.DESTROY, channel_id, thread_ts, ctx.user_id, said["reason"]
        )
        if guard_id is not None and said.get("note"):
            guards.keep_note(conn, guard_id, said["note_said"], card.note_words(said))

    if guard_id is None:
        return ctx.whisper("that thread is already held", channel_id, thread_ts)

    ctx.join(channel_id)
    with session() as conn:
        guards.warn(ctx.client, conn, guard_id, channel_id, thread_ts, guards.DESTROY)
        guards.refresh(conn)

    log.info("nemo: %s opened destroy guard %s on %s", ctx.user_id, guard_id, thread_ts)
    return guard_id
