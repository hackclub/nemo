import logging

from bot.core import access, outbox, session
from bot.nemo import answer, views, chat, memberguards, profile, surface, thread_commands
from bot.nemo.case_actions import (
    CASE_CATEGORY,
    family_root,
    has_open_report,
    mark_resolution_log_pending,
    log_action,
    merge,
    resolve_thread,
    resolve_with_action,
)
from bot.nemo.surface.reaction_watch import after_resolve
from bot.nemo.channel import (
    SUBJECTS,
    case_channels,
    post_action_log,
    post_ephemeral,
    post_merge_note,
    refresh_card,
)

log = logging.getLogger("bot.nemo")

RESOLVED_MARK = "check-check"


def register(app, on_reply=None):
    @app.action(views.edit.BAN_LOG)
    def on_ban_log(ack, body, client):
        ack()
        case_id, target = views.edit.parse_ban_value(body["actions"][0]["value"])
        if case_id is None:
            return None
        user_id = body["user"]["id"]
        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.act", case_id)
            if not allowed:
                return post_ephemeral(client, body, refusal)
            subjects = [row[0] for row in conn.execute(SUBJECTS, (case_id,)).fetchall()]
            category_row = conn.execute(CASE_CATEGORY, (case_id,)).fetchone()
        if target:
            subjects = [target, *[one for one in subjects if one != target]]
        return client.views_open(
            trigger_id=body["trigger_id"],
            view=views.action.build_view(case_id, subjects, category_row[0] if category_row else None),
        )

    def guard_status_for(conn, case_id, values):
        return memberguards.guard_status(
            conn,
            values.get("type_key"),
            values.get("target_user_id"),
            case_id,
            values.get("channel_id"),
        )

    def reshape_action_modal(ack, body, client):
        ack()
        submitted_view = body.get("view") or {}
        if submitted_view.get("callback_id") != views.action.CALLBACK:
            return

        case_id = int(submitted_view["private_metadata"])
        values = views.action.submitted_values(submitted_view["state"])
        with session() as conn:
            guard_status = guard_status_for(conn, case_id, values)
            open_report = has_open_report(conn, case_id)

        try:
            client.views_update(
                view_id=submitted_view["id"],
                hash=submitted_view["hash"],
                view=views.action.build_view(case_id, values=values, guard_status=guard_status,
                                             open_report=open_report),
            )
        except Exception as failure:
            log.warning("nemo: could not reshape the action modal: %s", failure)

    for where in (views.action.KIND, views.action.TARGET, views.action.WHERE, views.action.RESOLVE,
                  views.action.NOTIFY, views.action.CATEGORY):
        app.action(where)(reshape_action_modal)


    @app.view(views.action.CALLBACK)
    def on_action_logged(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        values = views.action.submitted_values(view["state"])
        values["timezone"] = getattr(profile.timezone(client, user_id), "key", "UTC")

        with session() as conn:
            guard_status = guard_status_for(conn, case_id, values)
            open_report = has_open_report(conn, case_id)

        block_ids = {block.get("block_id") for block in view.get("blocks", [])}
        if views.action.requires_refresh(values, block_ids, guard_status, open_report):
            return ack(
                response_action="update",
                view=views.action.build_view(case_id, values=values, guard_status=guard_status,
                                             open_report=open_report),
            )

        errors = views.action.validation_errors(values)
        if errors and views.action.UNTIL in errors:
            return ack(
                response_action="update",
                view=views.action.build_view(case_id, values=values, guard_status=guard_status,
                                             end_error=errors[views.action.UNTIL], open_report=open_report),
            )
        if errors:
            return ack(response_action="errors", errors=errors)

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.act", case_id)
            if allowed and views.action.deactivates(values["type_key"]):
                allowed, refusal = access.may(conn, user_id, "member.deactivate")
            if not allowed:
                return ack(
                    response_action="errors",
                    errors={views.action.KIND: refusal},
                )
            if values["resolve_case"]:
                allowed, refusal = access.may(conn, user_id, "case.resolve", case_id)
                if not allowed:
                    return ack(
                        response_action="errors",
                        errors={views.action.RESOLVE: refusal},
                    )
            current_guard_status = guard_status_for(conn, case_id, values)
            action_id = log_action(conn, case_id, values, user_id)
            guard_id = memberguards.apply_enforcement(conn, action_id, values, current_guard_status, user_id)
            resolution = resolve_with_action(conn, case_id, values, user_id)

        ack()
        with session() as conn:
            refresh_card(client, conn, case_id)
            post_action_log(client, conn, case_id, values, user_id)
        if resolution:
            after_resolve(client, case_id, resolution, user_id)
        log.info("nemo: action %s logged on case %s by %s, guard %s, resolved %s",
                 action_id, case_id, user_id, guard_id, resolution or "no")

    @app.view(views.merge.CALLBACK)
    def on_merged(ack, body, view, client):
        user_id = body["user"]["id"]
        values = views.merge.submitted_values(view["state"])

        errors = views.merge.validation_errors(values)
        if errors:
            return ack(response_action="errors", errors=errors)

        with session() as conn:
            for case_id in (values["target"], *values["duplicates"]):
                allowed, refusal = access.may(conn, user_id, "case.resolve", case_id)
                if not allowed:
                    return ack(response_action="errors", errors={views.merge.DUPLICATES: refusal})
            closed = merge(conn, values["target"], values["duplicates"], user_id)

        if not closed:
            return ack(
                response_action="errors",
                errors={views.merge.DUPLICATES: "Those cases are already resolved"},
            )

        ack(response_action="clear")
        with session() as conn:
            for case_id in closed:
                refresh_card(client, conn, case_id)
            post_merge_note(client, conn, values["target"], closed, user_id)
        log.info("nemo: cases %s merged into %s by %s", closed, values["target"], user_id)
        return None

    def post_refusal(event, thread_ts, client, refusal):
        try:
            client.reactions_add(
                channel=event["channel"], timestamp=event["ts"], name=answer.FAILED_REACTION
            )
            client.chat_postEphemeral(
                channel=event["channel"],
                user=event["user"],
                thread_ts=thread_ts,
                text=refusal,
            )
        except Exception as failure:
            log.warning("nemo: could not say why it was refused: %s", failure)

    def may_answer(event, thread_ts, client):
        with session() as conn:
            case_id = chat.case_of_thread(conn, thread_ts)
            allowed, refusal = access.may(conn, event.get("user"), "case.reply", case_id)
        if allowed:
            return True

        post_refusal(event, thread_ts, client, refusal)
        log.info("nemo: refused an answer from %s on case %s", event.get("user"), case_id)
        return False

    def on_message(event, client):
        if event.get("channel") not in case_channels():
            return

        subtype = event.get("subtype")
        if subtype == "message_changed":
            return on_changed(event, client)
        if subtype == "message_deleted":
            return on_deleted(event, client)
        if event.get("bot_id") or subtype not in (None, "file_share"):
            return

        thread_ts = event.get("thread_ts")
        if not thread_ts or thread_ts == event.get("ts"):
            return

        verb, args = thread_commands.parse_command(event.get("text"))
        if verb == thread_commands.RESOLVE:
            return resolve_from_thread(event, thread_ts, client)
        if verb:
            return thread_commands.handle(client, event, thread_ts, verb, args)

        parsed_answer = answer.read(event.get("text"))
        if parsed_answer and thread_reaches_reporter(thread_ts):
            return reply(event, thread_ts, parsed_answer, client)

        return record_chat(event, thread_ts, client)

    def resolve_from_thread(event, thread_ts, client):
        user_id = event.get("user")
        with session() as conn:
            case_id = chat.case_of_thread(conn, thread_ts)
            if case_id is None:
                return None
            report_id = chat.report_of_thread(conn, thread_ts)
            case_id = family_root(conn, case_id)
            for needed in ("case.reply", "case.resolve"):
                allowed, refusal = access.may(conn, user_id, needed, case_id)
                if not allowed:
                    break

        if not allowed:
            thread_commands.reply(client, event, thread_ts,
                                  thread_commands.refused_outcome(refusal))
            return None

        with session() as conn:
            resolution, notified = resolve_thread(
                conn, case_id, report_id, views.resolve.default_message(), user_id
            )
            if resolution and notified:
                mark_resolution_log_pending(conn, case_id, user_id)

        if resolution is None and not notified:
            thread_commands.reply(client, event, thread_ts,
                                  thread_commands.refused_outcome(views.lines.already_resolved(case_id)))
            return None

        if not thread_commands.delete_command(client, event["channel"], event["ts"], False):
            try:
                client.reactions_add(channel=event["channel"], timestamp=event["ts"],
                                     name=RESOLVED_MARK)
            except Exception as failure:
                log.warning("nemo: could not mark %s as done: %s", event["ts"], failure)
        if resolution:
            after_resolve(client, case_id, resolution, user_id, post_log=not notified)
        log.info("nemo: case %s resolved from the thread by %s, %s told", case_id, user_id, notified)
        return case_id

    def thread_reaches_reporter(thread_ts):
        with session() as conn:
            return chat.is_reporter_thread(conn, thread_ts)

    def reply(event, thread_ts, parsed_answer, client):
        if on_reply is None:
            return None
        if not may_answer(event, thread_ts, client):
            return None

        return on_reply(
            thread_ts,
            parsed_answer["body"],
            event.get("user"),
            signed=parsed_answer["signed"],
            files=event.get("files") or [],
            at=(event["channel"], event["ts"]),
        )

    def record_chat(event, thread_ts, client):
        with session() as conn:
            case_id = chat.case_of_thread(conn, thread_ts)
            if case_id is None:
                return
            allowed, refusal = access.may(conn, event.get("user"), "case.chat", case_id)

        if not allowed:
            post_refusal(event, thread_ts, client, refusal)
            log.info("nemo: refused chat from %s on case %s", event.get("user"), case_id)
            return

        with session() as conn:
            chat_id, inserted = chat.store_message(conn, case_id, event)

        if inserted:
            log.info("nemo: case %s heard us say something (%s)", case_id, chat_id)

    def on_changed(event, client):
        message = event.get("message") or {}
        if not message.get("ts") or message.get("subtype") == "bot_message":
            return
        parsed_answer = answer.read(message.get("text"))
        with session() as conn:
            changed = chat.edit(conn, event["channel"], message)
            edit_id = None
            if parsed_answer and parsed_answer["body"].strip():
                edit_id = outbox.edit_reply(conn, event["channel"], message["ts"], parsed_answer["body"],
                                            (message.get("edited") or {}).get("user") or message.get("user"))
        if changed:
            log.info("nemo: chat %s was edited", changed)
        if edit_id:
            log.info("nemo: reply at %s was edited, outbox %s carries it", message["ts"], edit_id)

    def on_deleted(event, client):
        if not event.get("deleted_ts"):
            return
        with session() as conn:
            deleted_id = chat.delete(conn, event["channel"], event["deleted_ts"])
            reply = outbox.reply_at(conn, event["channel"], event["deleted_ts"])
        if deleted_id:
            log.info("nemo: chat %s was deleted in slack, the words are kept", deleted_id)
        previous = event.get("previous_message") or {}
        if reply and previous.get("user"):
            try:
                client.chat_postEphemeral(channel=event["channel"], user=previous["user"],
                                          thread_ts=previous.get("thread_ts"), text=views.edits.MODERATOR_DELETE)
            except Exception as failure:
                log.warning("nemo: could not say the deletion was not forwarded: %s", failure)

    surface.bind(
        surface.EVENT, "message",
        lambda ctx: on_message(ctx.payload, ctx.client),
        tag="handlers.on_message",
    )
