import logging

from bot.core import access, session
from bot.nemo import answer, cards, chat, surface
from bot.nemo.casework import (
    CASE_CATEGORY,
    HELD_BY,
    OPEN_REPORTS,
    STILL_OPEN,
    add_participants,
    assign_people,
    claimed,
    counted,
    hand_back,
    keep_note,
    live_actions,
    log_action,
    participants,
    remove_assignee,
    remove_participant,
    reopen,
    resolve,
    reverse_action,
    set_category,
)
from bot.nemo.channel import ASSIGNEES, SUBJECTS, firehouse_channel, redraw, whisper

log = logging.getLogger("bot.nemo")


def register(app, on_reply=None):
    @app.action(cards.report.CLAIM)
    def on_claim(ack, body, client):
        ack()
        case_id = int(body["actions"][0]["value"])
        user_id = body["user"]["id"]

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.open")
            if not allowed:
                return whisper(client, body, refusal)
            if not conn.execute(STILL_OPEN, (case_id,)).fetchone()[0]:
                return whisper(client, body, f"case {case_id} is already resolved")
            held = [row[0] for row in conn.execute(HELD_BY, (case_id,)).fetchall()]
            if user_id in held:
                return whisper(client, body, f"case {case_id} is already yours")
            if held:
                who = ", ".join(f"<@{one}>" for one in held)
                return whisper(
                    client,
                    body,
                    f"case {case_id} is with {who}. Put yourself on it in Fire Engine "
                    "if you need to work it together.",
                )
            claimed(conn, case_id, user_id)

        log.info("nemo: case %s claimed by %s", case_id, user_id)

    @app.action(cards.report.LOG_ACTION)
    def on_log_action(ack, body, client):
        ack()
        case_id = int(body["actions"][0]["value"])
        user_id = body["user"]["id"]

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.act", case_id)
            if not allowed:
                return whisper(client, body, refusal)
            subjects = [row[0] for row in conn.execute(SUBJECTS, (case_id,)).fetchall()]
            held = conn.execute(CASE_CATEGORY, (case_id,)).fetchone()

        client.views_open(
            trigger_id=body["trigger_id"],
            view=cards.action.view(case_id, subjects, held[0] if held else None),
        )

    @app.action(cards.action.KIND)
    def on_action_kind(ack, body, client):
        ack()
        asked = body.get("view") or {}
        if asked.get("callback_id") != cards.action.CALLBACK:
            return

        case_id = int(asked["private_metadata"])
        said = cards.action.picked(asked["state"])
        try:
            client.views_update(
                view_id=asked["id"],
                hash=asked["hash"],
                view=cards.action.view(case_id, said=said),
            )
        except Exception as failure:
            log.warning("nemo: could not reshape the action modal: %s", failure)

    @app.view(cards.action.CALLBACK)
    def on_action_logged(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        said = cards.action.picked(view["state"])

        shown = {block.get("block_id") for block in view.get("blocks", [])}
        if cards.action.unasked(said, shown):
            return ack(
                response_action="update",
                view=cards.action.view(case_id, said=said),
            )

        wrong = cards.action.objection(said)
        if wrong:
            return ack(response_action="errors", errors=wrong)

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.act", case_id)
            if not allowed:
                return ack(
                    response_action="errors",
                    errors={cards.action.KIND: refusal},
                )
            action_id = log_action(conn, case_id, said, user_id)

        ack()
        with session() as conn:
            redraw(client, conn, case_id)
        log.info("nemo: action %s logged on case %s by %s", action_id, case_id, user_id)

    MORE = {
        cards.edit.CATEGORY: ("case.categorise", cards.edit.category_view),
        cards.edit.NOTE: ("case.note", cards.edit.note_view),
    }

    @app.action(cards.edit.MENU)
    def on_more(ack, body, client):
        ack()
        verb, case_id = cards.edit.asked(body["actions"][0]["selected_option"]["value"])
        user_id = body["user"]["id"]
        if case_id is None:
            return None

        if verb == cards.edit.HAND_BACK:
            return on_hand_back(body, client, case_id, user_id)
        if verb == cards.edit.REVERSE:
            return on_reverse_asked(body, client, case_id, user_id)
        if verb == cards.edit.PEOPLE:
            return on_people_asked(body, client, case_id, user_id)
        if verb == cards.edit.ASSIGNEES:
            return on_assignees_asked(body, client, case_id, user_id)

        wanted = MORE.get(verb)
        if wanted is None:
            return None

        key, view_of = wanted
        with session() as conn:
            allowed, refusal = access.may(conn, user_id, key, case_id)
        if not allowed:
            return whisper(client, body, refusal)

        client.views_open(trigger_id=body["trigger_id"], view=view_of(case_id))
        return None

    def on_reverse_asked(body, client, case_id, user_id):
        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.reverse", case_id)
            if not allowed:
                return whisper(client, body, refusal)
            live = live_actions(conn, case_id)

        if not live:
            return whisper(client, body, f"nothing live to reverse on *case {case_id}*")

        client.views_open(
            trigger_id=body["trigger_id"],
            view=cards.reverse.view(case_id, live),
        )
        return None

    @app.view(cards.reverse.CALLBACK)
    def on_reversed(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        said = cards.reverse.picked(view["state"])

        wrong = cards.reverse.objection(said)
        if wrong:
            return ack(response_action="errors", errors=wrong)

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.reverse", case_id)
            if not allowed:
                return ack(response_action="errors", errors={cards.reverse.WHICH: refusal})
            done = reverse_action(conn, case_id, said["action_id"], said["reason"], user_id)

        if not done:
            return ack(
                response_action="errors",
                errors={cards.reverse.WHICH: "That action is not live on this case anymore."},
            )

        ack()
        with session() as conn:
            redraw(client, conn, case_id)
        log.info("nemo: action %s reversed on case %s by %s", said["action_id"], case_id, user_id)

    def on_hand_back(body, client, case_id, user_id):
        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.open", case_id)
            if not allowed:
                return whisper(client, body, refusal)
            given = hand_back(conn, case_id, user_id)

        if not given:
            return whisper(client, body, f"case {case_id} is not yours to hand back")

        with session() as conn:
            redraw(client, conn, case_id)
        log.info("nemo: case %s handed back by %s", case_id, user_id)
        return None

    def on_people_asked(body, client, case_id, user_id):
        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.people", case_id)
            if not allowed:
                return whisper(client, body, refusal)
            held = participants(conn, case_id)

        client.views_open(
            trigger_id=body["trigger_id"],
            view=cards.people.view(case_id, held),
        )
        return None

    @app.action(cards.people.REMOVE)
    def on_people_removed(ack, body, client):
        ack()
        user_id, role, case_id = cards.people.removed(body["actions"][0]["value"])
        actor = body["user"]["id"]
        if case_id is None:
            return None

        with session() as conn:
            allowed, refusal = access.may(conn, actor, "case.people", case_id)
            if not allowed:
                return whisper(client, body, refusal)
            remove_participant(conn, case_id, user_id, role, actor)
            held = participants(conn, case_id)

        try:
            client.views_update(
                view_id=body["view"]["id"],
                hash=body["view"]["hash"],
                view=cards.people.view(case_id, held),
            )
        except Exception as failure:
            log.warning("nemo: could not refresh the people modal: %s", failure)

        with session() as conn:
            redraw(client, conn, case_id)
        log.info("nemo: %s taken off case %s (%s) by %s", user_id, case_id, role, actor)
        return None

    @app.view(cards.people.CALLBACK)
    def on_people_submitted(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        said = cards.people.picked(view["state"])

        wrong = cards.people.objection(said)
        if wrong:
            return ack(response_action="errors", errors=wrong)

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.people", case_id)
            if not allowed:
                return ack(response_action="errors", errors={cards.people.WHO: refusal})
            added = add_participants(
                conn, case_id, said["user_ids"], said["role"], user_id
            )
            held = participants(conn, case_id)

        ack(response_action="update", view=cards.people.view(case_id, held))
        with session() as conn:
            redraw(client, conn, case_id)
        already = [one for one in said["user_ids"] if one not in added]
        log.info("nemo: case %s people added %s (already: %s) by %s",
                 case_id, added, already, user_id)
        return None

    def on_assignees_asked(body, client, case_id, user_id):
        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.open", case_id)
            if not allowed:
                return whisper(client, body, refusal)
            held = [row[0] for row in conn.execute(ASSIGNEES, (case_id,)).fetchall()]

        client.views_open(
            trigger_id=body["trigger_id"],
            view=cards.assignees.view(case_id, held),
        )
        return None

    @app.action(cards.assignees.REMOVE)
    def on_assignee_removed(ack, body, client):
        ack()
        user_id, case_id = cards.assignees.removed(body["actions"][0]["value"])
        actor = body["user"]["id"]
        if case_id is None:
            return None

        with session() as conn:
            allowed, refusal = access.may(conn, actor, "case.open", case_id)
            if not allowed:
                return whisper(client, body, refusal)
            remove_assignee(conn, case_id, user_id, actor)
            held = [row[0] for row in conn.execute(ASSIGNEES, (case_id,)).fetchall()]

        try:
            client.views_update(
                view_id=body["view"]["id"],
                hash=body["view"]["hash"],
                view=cards.assignees.view(case_id, held),
            )
        except Exception as failure:
            log.warning("nemo: could not refresh the assignees modal: %s", failure)

        with session() as conn:
            redraw(client, conn, case_id)
        log.info("nemo: %s taken off case %s by %s", user_id, case_id, actor)
        return None

    @app.view(cards.assignees.CALLBACK)
    def on_assignees_submitted(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        said = cards.assignees.picked(view["state"])

        wrong = cards.assignees.objection(said)
        if wrong:
            return ack(response_action="errors", errors=wrong)

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.open", case_id)
            if not allowed:
                return ack(response_action="errors", errors={cards.assignees.WHO: refusal})
            if not conn.execute(STILL_OPEN, (case_id,)).fetchone()[0]:
                return ack(
                    response_action="errors",
                    errors={cards.assignees.WHO: f"case {case_id} is already resolved"},
                )
            added = assign_people(conn, case_id, said["user_ids"], user_id)
            held = [row[0] for row in conn.execute(ASSIGNEES, (case_id,)).fetchall()]

        ack(response_action="update", view=cards.assignees.view(case_id, held))
        with session() as conn:
            redraw(client, conn, case_id)
        already = [one for one in said["user_ids"] if one not in added]
        log.info("nemo: case %s assignees added %s (already: %s) by %s",
                 case_id, added, already, user_id)
        return None

    @app.view(cards.edit.CATEGORY)
    def on_category(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        key = cards.edit.what_picked(view["state"])

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.categorise", case_id)
            if not allowed:
                return ack(response_action="errors", errors={cards.edit.WHAT: refusal})
            settled = set_category(conn, case_id, key, user_id)

        if not settled:
            return ack(
                response_action="errors",
                errors={cards.edit.WHAT: f"Case {case_id} already has a category."},
            )

        ack()
        with session() as conn:
            redraw(client, conn, case_id)
        log.info("nemo: case %s is %s", case_id, key)
        return None

    @app.view(cards.edit.NOTE)
    def on_note(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        said = cards.edit.said_picked(view["state"])

        wrong = cards.edit.note_objection(said)
        if wrong:
            return ack(response_action="errors", errors=wrong)

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.note", case_id)
            if not allowed:
                return ack(response_action="errors", errors={cards.edit.SAID: refusal})
            note_id = keep_note(conn, case_id, said, user_id)

        ack()
        log.info("nemo: note %s kept on case %s", note_id, case_id)
        return None

    @app.action(cards.report.REOPEN)
    def on_reopen(ack, body, client):
        ack()
        case_id = int(body["actions"][0]["value"])
        user_id = body["user"]["id"]

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.reopen", case_id)
            if not allowed:
                return whisper(client, body, refusal)
            back = reopen(conn, case_id, user_id)

        if not back:
            return whisper(client, body, f"case {case_id} is already open")

        with session() as conn:
            redraw(client, conn, case_id)
        log.info("nemo: case %s reopened by %s", case_id, user_id)
        return None

    @app.action(cards.report.RESOLVE)
    def on_resolve_asked(ack, body, client):
        ack()
        case_id = int(body["actions"][0]["value"])
        user_id = body["user"]["id"]

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.resolve", case_id)
            if not allowed:
                return whisper(client, body, refusal)
            live = live_actions(conn, case_id)
            open_ones = counted(conn, OPEN_REPORTS, case_id)

        client.views_open(
            trigger_id=body["trigger_id"],
            view=cards.resolve.view(case_id, live, open_ones),
        )

    @app.view(cards.resolve.CALLBACK)
    def on_resolved(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]

        with session() as conn:
            live = live_actions(conn, case_id)
        said = cards.resolve.picked(view["state"], live)

        wrong = cards.resolve.objection(said)
        if wrong:
            return ack(response_action="errors", errors=wrong)

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.resolve", case_id)
            if not allowed:
                return ack(response_action="errors", errors={cards.resolve.WHY: refusal})
            told = resolve(conn, case_id, said, user_id)

        if told is None:
            return ack(
                response_action="errors",
                errors={cards.resolve.WHY: f"Case {case_id} was already resolved."},
            )

        ack()
        with session() as conn:
            redraw(client, conn, case_id)
        log.info("nemo: case %s resolved by %s, %s told", case_id, user_id, told)

    def say_no(event, thread_ts, client, said, refusal):
        try:
            client.reactions_add(
                channel=event["channel"], timestamp=event["ts"], name=answer.STUCK
            )
            client.chat_postEphemeral(
                channel=event["channel"],
                user=event["user"],
                thread_ts=thread_ts,
                text=f"{said}. {refusal}",
            )
        except Exception as failure:
            log.warning("nemo: could not say why it was refused: %s", failure)

    def may_answer(event, thread_ts, client):
        with session() as conn:
            case_id = chat.case_of_thread(conn, thread_ts)
            allowed, refusal = access.may(conn, event.get("user"), "case.reply", case_id)
        if allowed:
            return True

        say_no(event, thread_ts, client, "nothing was sent", refusal)
        log.info("nemo: refused an answer from %s on case %s", event.get("user"), case_id)
        return False

    def on_message(event, client):
        if event.get("channel") != firehouse_channel():
            return

        subtype = event.get("subtype")
        if subtype == "message_changed":
            return on_changed(event)
        if subtype == "message_deleted":
            return on_deleted(event)
        if event.get("bot_id") or subtype not in (None, "file_share"):
            return

        thread_ts = event.get("thread_ts")
        if not thread_ts or thread_ts == event.get("ts"):
            return

        aimed = answer.read(event.get("text"))
        if aimed is None:
            return ours(event, thread_ts, client)

        if on_reply is None:
            return
        if not may_answer(event, thread_ts, client):
            return
        on_reply(
            thread_ts,
            aimed["said"],
            event.get("user"),
            signed=aimed["signed"],
            files=event.get("files") or [],
            at=(event["channel"], event["ts"]),
        )

    def ours(event, thread_ts, client):
        with session() as conn:
            case_id = chat.case_of_thread(conn, thread_ts)
            if case_id is None:
                return
            allowed, refusal = access.may(conn, event.get("user"), "case.chat", case_id)

        if not allowed:
            say_no(event, thread_ts, client, "nothing was kept", refusal)
            log.info("nemo: refused chat from %s on case %s", event.get("user"), case_id)
            return

        with session() as conn:
            chat_id, fresh = chat.keep(conn, case_id, event)

        if fresh:
            log.info("nemo: case %s heard us say something (%s)", case_id, chat_id)

    def on_changed(event):
        message = event.get("message") or {}
        if not message.get("ts") or message.get("subtype") == "bot_message":
            return
        with session() as conn:
            changed = chat.edit(conn, event["channel"], message)
        if changed:
            log.info("nemo: chat %s was edited", changed)

    def on_deleted(event):
        if not event.get("deleted_ts"):
            return
        with session() as conn:
            gone = chat.delete(conn, event["channel"], event["deleted_ts"])
        if gone:
            log.info("nemo: chat %s was deleted in slack, the words are kept", gone)

    surface.bind(
        surface.EVENT, "message",
        lambda ctx: on_message(ctx.payload, ctx.client),
        tag="handlers.on_message",
    )
