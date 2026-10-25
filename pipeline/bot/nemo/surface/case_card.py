import logging

from bot.core import access, session
from bot.nemo import case_actions, case_modal, case_queue, channel, profile, thread_commands, views
from bot.nemo.surface import on_action, on_view
from bot.nemo.surface.reaction_watch import after_reopen, after_resolve

log = logging.getLogger("bot.nemo")

card = views.case_card
menu = views.case_menu

STILL_OPEN = case_actions.STILL_OPEN
CASE_CATEGORY = case_actions.CASE_CATEGORY
SUBJECTS = channel.SUBJECTS

ALREADY_OPEN = "Case {case_id} is already open"
ALREADY_RESOLVED = "Case {case_id} is already resolved"
UNCHANGED_CATEGORY = "Category unchanged"
NOT_ASSIGNED = "Select an assignee"
NO_MEMBER = "Select a member"


def action_case_id(ctx):
    for one in ctx.body.get("actions") or []:
        value = str(one.get("value") or "")
        if value.isdigit():
            return int(value)
    return None


def view_case_id(ctx):
    value = ctx.view.get("private_metadata") or ""
    return int(value) if value.isdigit() else None


def refresh(client, case_id):
    with session() as conn:
        channel.refresh_card(client, conn, case_id)
        case_queue.refresh_card(client, conn, case_id)


def say(client, case_id, lines):
    with session() as conn:
        for text in lines:
            channel.post_line(client, conn, case_id, text)


def more_for(conn, case_id, notice=None):
    open_row = conn.execute(STILL_OPEN, (case_id,)).fetchone()
    return menu.more_view(
        case_id,
        thread_commands.current_assignees(conn, case_id),
        url=channel.case_url(case_id),
        is_open=bool(open_row and open_row[0]),
        notice=notice,
    )


def update_more(ctx, case_id, notice=None):
    with session() as conn:
        view = more_for(conn, case_id, notice)
    try:
        ctx.client.views_update(view_id=ctx.view["id"], hash=ctx.view["hash"], view=view)
    except Exception as failure:
        log.warning("nemo: could not refresh the case menu for case %s: %s", case_id, failure)


def in_case_view(ctx):
    return ctx.view.get("callback_id") == views.case_view.CALLBACK


def update_case_view(ctx, case_id, notice=None):
    with session() as conn:
        view = case_modal.build(ctx.client, conn, case_id, notice)
    if view is None:
        return None
    try:
        ctx.client.views_update(view_id=ctx.view["id"], hash=ctx.view["hash"], view=view)
    except Exception as failure:
        log.warning("nemo: could not refresh the case view for case %s: %s", case_id, failure)
    return case_id


def show(ctx, view):
    if ctx.view:
        return ctx.client.views_push(trigger_id=ctx.trigger_id, view=view)
    return ctx.client.views_open(trigger_id=ctx.trigger_id, view=view)


def run_thread_command(ctx, verb, args, case_id):
    outcome = thread_commands.run(verb, args, case_id, ctx.user_id)
    if outcome["refused"]:
        return outcome
    say(ctx.client, case_id, outcome["say"])
    refresh(ctx.client, case_id)
    return outcome


@on_action(card.CLAIM, needs="case.open")
def claim_from_card(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    outcome = run_thread_command(ctx, thread_commands.CLAIM, "", case_id)
    if in_case_view(ctx):
        return update_case_view(ctx, case_id, outcome["refused"])
    if outcome["refused"]:
        ctx.post_ephemeral(outcome["refused"])
    return case_id


@on_action(card.RESOLVE, needs="case.resolve")
def open_resolve(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    with session() as conn:
        resolution = case_actions.default_resolution(conn, case_id)
    return show(ctx, menu.resolve_view(case_id, resolution))


@on_action(card.REOPEN, needs="case.reopen")
def reopen_from_card(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    with session() as conn:
        reopened = case_actions.reopen(conn, case_id, ctx.user_id)
    if not reopened:
        if in_case_view(ctx):
            return update_case_view(ctx, case_id, ALREADY_OPEN.format(case_id=case_id))
        return ctx.post_ephemeral(ALREADY_OPEN.format(case_id=case_id))
    after_reopen(ctx.client, case_id, ctx.user_id)
    if in_case_view(ctx):
        return update_case_view(ctx, case_id)
    return case_id


@on_action(card.REOPEN_AFTER_REPLY, needs="case.reopen")
def reopen_after_reply(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    with session() as conn:
        reopened = case_actions.reopen(conn, case_id, ctx.user_id)
    if not reopened:
        return ctx.post_ephemeral(ALREADY_OPEN.format(case_id=case_id))
    refresh(ctx.client, case_id)
    try:
        ctx.client.chat_update(channel=ctx.channel_id, ts=ctx.message_ts,
                               text=views.lines.reopened_by_reporter(case_id), blocks=[])
    except Exception as failure:
        log.warning("nemo: could not update the reopen prompt for case %s: %s", case_id, failure)
    return case_id


@on_action(card.LOG_ACTION, needs="case.act")
def open_log_action(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    with session() as conn:
        subjects = [row[0] for row in conn.execute(SUBJECTS, (case_id,)).fetchall()]
        category_row = conn.execute(CASE_CATEGORY, (case_id,)).fetchone()
    return show(ctx, views.action.build_view(case_id, subjects, category_row[0] if category_row else None))


@on_action(card.MORE, needs="case.read")
def open_more(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    with session() as conn:
        view = more_for(conn, case_id)
    return show(ctx, view)


@on_action(menu.MENU_CLAIM, needs="case.open")
def claim_from_menu(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    outcome = run_thread_command(ctx, thread_commands.CLAIM, "", case_id)
    return update_more(ctx, case_id, outcome["refused"])


@on_action(menu.MENU_ASSIGN, needs="case.open")
def open_assign(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    with session() as conn:
        assignees = thread_commands.current_assignees(conn, case_id)
    return ctx.client.views_push(trigger_id=ctx.trigger_id, view=menu.assign_view(case_id, assignees))


@on_action(menu.MENU_UNASSIGN, needs="case.open")
def open_unassign(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    with session() as conn:
        assignees = thread_commands.current_assignees(conn, case_id)
    if len(assignees) == 1:
        outcome = run_thread_command(ctx, thread_commands.UNASSIGN, f"<@{assignees[0]}>", case_id)
        return update_more(ctx, case_id, outcome["refused"])
    named = [(one, profile.name(ctx.client, one)) for one in assignees]
    return ctx.client.views_push(trigger_id=ctx.trigger_id, view=menu.unassign_view(case_id, named))


@on_action(menu.MENU_NOTE, needs="case.note")
def open_note(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    return ctx.client.views_push(trigger_id=ctx.trigger_id, view=menu.note_view(case_id))


@on_action(menu.MENU_MERGE, needs="case.resolve")
def open_merge(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    with session() as conn:
        cases = case_actions.mergeable(conn, [case_id])
    return ctx.client.views_push(trigger_id=ctx.trigger_id,
                                 view=views.merge.build_view(cases, None, [case_id]))


@on_action(menu.MENU_CATEGORY, needs="case.categorise")
def open_category(ctx):
    case_id = action_case_id(ctx)
    if case_id is None:
        return None
    with session() as conn:
        category_row = conn.execute(CASE_CATEGORY, (case_id,)).fetchone()
    return ctx.client.views_push(
        trigger_id=ctx.trigger_id,
        view=menu.category_view(case_id, category_row[0] if category_row else None),
    )


@on_action(menu.NOTE_TARGET, needs="case.note")
def reshape_note(ctx):
    view = ctx.view
    if view.get("callback_id") != menu.NOTE_CALLBACK:
        return None
    case_id = view_case_id(ctx)
    values = menu.note_values(view.get("state") or {})
    try:
        ctx.client.views_update(
            view_id=view["id"], hash=view["hash"],
            view=menu.note_view(case_id, values["on_member"], values["member"], values["text"]),
        )
    except Exception as failure:
        log.warning("nemo: could not reshape the note modal: %s", failure)
    return None


def mentions_of(user_ids):
    return " ".join(f"<@{one}>" for one in user_ids)


@on_view(menu.ASSIGN_CALLBACK, needs="case.open", refuse_block=menu.ASSIGN_TO)
def submit_assign(ctx):
    case_id = view_case_id(ctx)
    user_ids = menu.assign_values(ctx.view.get("state") or {})
    if not user_ids:
        return ctx.ack(response_action="errors", errors={menu.ASSIGN_TO: NOT_ASSIGNED})
    outcome = thread_commands.run(thread_commands.ASSIGN, mentions_of(user_ids), case_id, ctx.user_id)
    if outcome["refused"]:
        return ctx.ack(response_action="errors", errors={menu.ASSIGN_TO: outcome["refused"]})
    ctx.ack(response_action="clear")
    say(ctx.client, case_id, outcome["say"])
    refresh(ctx.client, case_id)
    return case_id


@on_view(menu.UNASSIGN_CALLBACK, needs="case.open", refuse_block=menu.UNASSIGN_FROM)
def submit_unassign(ctx):
    case_id = view_case_id(ctx)
    user_ids = menu.unassign_values(ctx.view.get("state") or {})
    if not user_ids:
        return ctx.ack(response_action="errors", errors={menu.UNASSIGN_FROM: NOT_ASSIGNED})
    outcome = thread_commands.run(thread_commands.UNASSIGN, mentions_of(user_ids), case_id, ctx.user_id)
    if outcome["refused"]:
        return ctx.ack(response_action="errors", errors={menu.UNASSIGN_FROM: outcome["refused"]})
    ctx.ack(response_action="clear")
    say(ctx.client, case_id, outcome["say"])
    refresh(ctx.client, case_id)
    return case_id


@on_view(menu.NOTE_CALLBACK, open_to_all=True)
def submit_note(ctx):
    case_id = view_case_id(ctx)
    values = menu.note_values(ctx.view.get("state") or {})
    needed = "member.note" if values["on_member"] else "case.note"
    with session() as conn:
        allowed, refusal = access.may(conn, ctx.user_id, needed, case_id)
        if not allowed:
            return ctx.ack(response_action="errors", errors={menu.NOTE_TEXT: refusal})
        if values["on_member"] and not values["member"]:
            return ctx.ack(response_action="errors", errors={menu.NOTE_MEMBER: NO_MEMBER})
        if values["on_member"]:
            case_actions.member_note(conn, values["member"], values["text"], ctx.user_id)
        else:
            case_actions.add_note(conn, case_id, values["text"], ctx.user_id)
    ctx.ack(response_action="clear")
    return case_id


@on_view(menu.CATEGORY_CALLBACK, needs="case.categorise", refuse_block=menu.CATEGORY_KEY)
def submit_category(ctx):
    case_id = view_case_id(ctx)
    category_key = menu.category_value(ctx.view.get("state") or {})
    if category_key not in views.edit.categories():
        return ctx.ack(response_action="errors", errors={menu.CATEGORY_KEY: "Select a category"})
    with session() as conn:
        changed = case_actions.set_category(conn, case_id, category_key, ctx.user_id)
    if not changed:
        return ctx.ack(response_action="errors", errors={menu.CATEGORY_KEY: UNCHANGED_CATEGORY})
    ctx.ack(response_action="clear")
    refresh(ctx.client, case_id)
    return case_id


@on_view(menu.RESOLVE_CALLBACK, needs="case.resolve", refuse_block=menu.RESOLUTION)
def submit_resolve(ctx):
    case_id = view_case_id(ctx)
    values = menu.resolve_values(ctx.view.get("state") or {})
    if not values["resolution"]:
        return ctx.ack(response_action="errors", errors={menu.RESOLUTION: "Select a resolution"})
    with session() as conn:
        if values["notify_reporter"]:
            allowed, refusal = access.may(conn, ctx.user_id, "case.reply", case_id)
            if not allowed:
                return ctx.ack(response_action="errors", errors={menu.REPORTER_MESSAGE: refusal})
        notified = case_actions.resolve(conn, case_id, values, ctx.user_id)
        if notified is None:
            return ctx.ack(response_action="errors",
                           errors={menu.RESOLUTION: ALREADY_RESOLVED.format(case_id=case_id)})
        if notified:
            case_actions.mark_resolution_log_pending(conn, case_id, ctx.user_id)
    ctx.ack(response_action="clear")
    after_resolve(ctx.client, case_id, values["resolution"], ctx.user_id, post_log=not notified)
    return case_id
