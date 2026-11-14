import logging

from bot.core import session
from bot.nemo import channels, guard_actions, guards, profile
from bot.nemo.views import guard as card
from bot.nemo.surface import on_action, on_shortcut, on_view

log = logging.getLogger("bot.nemo")

SHORTCUT = "lock_thread"

NOT_A_THREAD = "That message is not a thread."
BEING_DESTROYED = "Thread already being destroyed"
ALREADY_LOCKED = "Thread already locked"
ALREADY_ENDED = "Lock already ended"
UNLOCKED = "Thread unlocked"

WARNING_NOT_POSTED = "Thread not locked: Nemo could not post in this thread ({error_code}), /invite @nemo"


def live_lock(channel_id, thread_ts):
    with session() as conn:
        return guards.live_on_thread(conn, channel_id, thread_ts)


def view_for(channel_id, thread_ts, current, tz, values=None, end_error=None):
    if current:
        return card.locked_view(channel_id, thread_ts, current, tz, values, end_error)
    return card.lock_view(channel_id, thread_ts, values, end_error)


@on_shortcut(SHORTCUT, needs="thread.guard")
def open_lock_modal(ctx):
    if not ctx.thread_ts:
        return ctx.post_ephemeral(NOT_A_THREAD)

    current = live_lock(ctx.channel_id, ctx.thread_ts)
    if current and current["kind"] == guards.DESTROY:
        return ctx.post_ephemeral(BEING_DESTROYED)

    tz = profile.timezone(ctx.client, ctx.user_id)
    ctx.client.views_open(trigger_id=ctx.trigger_id, view=view_for(ctx.channel_id, ctx.thread_ts, current, tz))
    return None


@on_action(card.UNLOCK, needs="thread.guard")
def unlock_thread(ctx):
    view = ctx.view
    if view.get("callback_id") != card.LOCK_CALLBACK:
        return None

    channel_id, thread_ts = card.parse_metadata(view)
    current = live_lock(channel_id, thread_ts)
    lifted = None
    if current and current["kind"] == guards.LOCK:
        lifted = guard_actions.lift_lock(ctx.client, current["id"], by=ctx.user_id)

    try:
        ctx.client.views_update(view_id=view["id"], hash=view.get("hash"), view=card.unlocked_view())
    except Exception as failure:
        log.warning("nemo: could not close the lock modal: %s", failure)

    ctx.post_ephemeral(UNLOCKED if lifted else ALREADY_ENDED, channel_id, thread_ts)
    return lifted


@on_action(card.NOTICE_MENU, needs="thread.guard", silent_refusal=True)
def unlock_from_notice(ctx):
    if card.selected_option(ctx.body) != card.NOTICE_UNLOCK:
        return None

    channel_id, thread_ts = ctx.channel_id, ctx.thread_ts
    current = live_lock(channel_id, thread_ts)
    lifted = None
    if current and current["kind"] == guards.LOCK:
        lifted = guard_actions.lift_lock(ctx.client, current["id"], by=ctx.user_id)

    ctx.post_ephemeral(UNLOCKED if lifted else ALREADY_ENDED, channel_id, thread_ts)
    return lifted


def lock(ctx, channel_id, thread_ts, values, tz):
    expires_at = card.lock_end(values, tz)
    with session() as conn:
        guard_id = guards.open_guard(
            conn, guards.LOCK, channel_id, thread_ts, ctx.user_id, values["reason"],
            expires_at=expires_at,
        )
    if guard_id is None:
        return ctx.post_ephemeral(ALREADY_LOCKED, channel_id, thread_ts)

    ctx.join(channel_id)
    error_code = None
    with session() as conn:
        notice = guard_actions.lock_notice(conn, expires_at, values["reason"])
        try:
            guards.warn(ctx.client, conn, guard_id, channel_id, thread_ts, guards.LOCK, notice=notice)
        except Exception as failure:
            error_code = channels.slack_error_code(failure)
            guards.finish(conn, guard_id, "failed", f"warning not posted: {error_code}")
        guards.refresh(conn)

    if error_code:
        log.warning("nemo: lock guard %s failed, warning not posted: %s", guard_id, error_code)
        ctx.post_ephemeral(WARNING_NOT_POSTED.format(error_code=error_code), channel_id, thread_ts)
        return None

    log.info("nemo: %s locked %s until %s (guard %s)", ctx.user_id, thread_ts, expires_at, guard_id)
    return guard_id


def extend(ctx, channel_id, thread_ts, values, tz):
    with session() as conn:
        current = guards.live_on_thread(conn, channel_id, thread_ts)
        if not current or current["kind"] != guards.LOCK:
            return ctx.post_ephemeral(ALREADY_ENDED, channel_id, thread_ts)
        expires_at = card.lock_end(values, tz)
        guard_id = guards.extend(conn, current, expires_at, ctx.user_id)
        guards.refresh(conn)

    if guard_id is None:
        return ctx.post_ephemeral(ALREADY_ENDED, channel_id, thread_ts)
    guard_actions.update_lock_notice(ctx.client, guard_id)
    log.info("nemo: %s extended lock %s to %s", ctx.user_id, guard_id, expires_at)
    return guard_id


@on_view(card.LOCK_CALLBACK, needs="thread.guard", refuse_block=card.REASON)
def submit_lock(ctx):
    extending = card.is_extending(ctx.view)
    values = card.submitted_values(ctx.view.get("state") or {}, extending)
    channel_id, thread_ts = card.parse_metadata(ctx.view)
    tz = profile.timezone(ctx.client, ctx.user_id)
    current = live_lock(channel_id, thread_ts) if extending and channel_id and thread_ts else None
    errors = card.lock_errors(values, tz)
    if errors and card.END in errors:
        if not extending or current:
            return ctx.ack(response_action="update",
                           view=view_for(channel_id, thread_ts, current, tz, values, errors[card.END]))
    elif errors:
        return ctx.ack(response_action="errors", errors=errors)

    ctx.ack()
    if not channel_id or not thread_ts:
        return None
    if values["starting"]:
        return lock(ctx, channel_id, thread_ts, values, tz)
    return extend(ctx, channel_id, thread_ts, values, tz)
