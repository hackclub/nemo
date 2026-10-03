import logging

from bot.core import session
from bot.nemo import guards
from bot.nemo.views import guard as card
from bot.nemo.surface import on_action, on_shortcut, on_view

log = logging.getLogger("bot.nemo")

SHORTCUT = "destroy_thread"


@on_shortcut(SHORTCUT, needs="thread.guard")
def asked(ctx):
    if not ctx.thread_ts:
        return ctx.post_ephemeral("that is not a thread")

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
    values = card.submitted_values(view.get("state") or {})
    try:
        ctx.client.views_update(
            view_id=view["id"],
            hash=view["hash"],
            view=card.destroy_view(channel_id, thread_ts, values=values),
        )
    except Exception as failure:
        log.warning("nemo: could not reshape the destroy modal: %s", failure)
    return None


@on_view(card.DESTROY_CALLBACK, needs="thread.guard", refuse_block=card.REASON)
def confirmed(ctx):
    values = card.submitted_values(ctx.view.get("state") or {})
    wrong = card.validation_errors(values)
    if wrong:
        return ctx.ack(response_action="errors", errors=wrong)

    ctx.ack()
    channel_id, thread_ts = card.opened(ctx.view)
    if not channel_id or not thread_ts:
        return None

    with session() as conn:
        guard_id = guards.open_guard(
            conn, guards.DESTROY, channel_id, thread_ts, ctx.user_id, values["reason"]
        )
        if guard_id is not None and values.get("note"):
            guards.keep_note(conn, guard_id, values["note_body"], card.note_text(values))

    if guard_id is None:
        return ctx.post_ephemeral("that thread is already held", channel_id, thread_ts)

    ctx.join(channel_id)
    with session() as conn:
        guards.warn(ctx.client, conn, guard_id, channel_id, thread_ts, guards.DESTROY)
        guards.refresh(conn)

    log.info("nemo: %s opened destroy guard %s on %s", ctx.user_id, guard_id, thread_ts)
    return guard_id
