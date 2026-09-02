import logging
import os

from psycopg.types.json import Jsonb

from bot.engine import access, audit, parse, session
from bot.nemo import answer, chat, who
from bot.nemo import cards
from bot.nemo import files as carry

log = logging.getLogger("bot.nemo")

CASE = """
SELECT c.id, c.category_key, c.resolved_at,
       r.id, r.is_anonymous, r.reporter_user_id, r.body, r.forwarded_ts, r.received_at,
       v.id, r.card_digest
FROM fd.cases c
JOIN fd.case_reports r ON r.case_id = c.id
LEFT JOIN fd.intake_conversations v ON v.report_id = r.id
WHERE c.id = %s
ORDER BY r.id
LIMIT 1
"""

SUBJECTS = """
SELECT user_id FROM fd.case_participants
WHERE case_id = %s AND role = 'subject'
ORDER BY user_id
"""

ASSIGNEES = """
SELECT user_id FROM fd.case_assignees WHERE case_id = %s ORDER BY assigned_at
"""

OTHER_CASES = """
SELECT count(DISTINCT case_id) FROM fd.case_participants
WHERE role = 'subject' AND case_id <> %s AND user_id = ANY(%s)
"""

FIRST_MESSAGE = """
SELECT id, body, mirrored_ts
FROM fd.intake_messages
WHERE conversation_id = %s AND direction = 'inbound'
ORDER BY posted_at, id
LIMIT 1
"""

FILES = """
SELECT f.slack_file_id, f.name, f.fetch_state, f.external_url
FROM fd.intake_message_files mf
JOIN fd.intake_files f ON f.id = mf.file_id
JOIN fd.intake_messages m ON m.id = mf.message_id
WHERE m.conversation_id = %s
ORDER BY m.posted_at, mf.seq
"""

THREADS = """
SELECT count(*) FROM fd.case_threads WHERE case_id = %s AND kind = 'evidence'
"""

SHARES = """
SELECT s.kind, s.source_channel_id, s.source_channel_name, s.source_ts, s.permalink,
       s.is_reachable, s.source_author_user_id, s.source_body
FROM fd.intake_shares s
JOIN fd.intake_messages m ON m.id = s.message_id
WHERE m.conversation_id = %s
ORDER BY m.posted_at, s.id
"""


FOLLOW_UP = """
SELECT m.body, m.mirrored_ts, r.forwarded_ts, m.conversation_id,
       r.is_anonymous, r.reporter_user_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
LEFT JOIN fd.case_reports r ON r.id = c.report_id
WHERE m.id = %s
"""

ANONYMOUS = "Anonymous reporter"

HELD_BY = """
SELECT user_id FROM fd.case_assignees WHERE case_id = %s ORDER BY assigned_at
"""

CLAIM = """
INSERT INTO fd.case_assignees (case_id, user_id, assigned_by) VALUES (%s, %s, %s)
ON CONFLICT DO NOTHING
"""

STILL_OPEN = """
SELECT resolved_at IS NULL FROM fd.cases WHERE id = %s
"""


def digest_of(blocks):
    return parse.digest(None, blocks, None)


def firehouse_channel():
    return os.environ["FIREHOUSE_CHANNEL_ID"]


def app_url(path):
    host = os.environ.get("APP_HOST")
    if not host:
        return None
    scheme = "http" if host.startswith("localhost") or host.startswith("127.") else "https"
    return f"{scheme}://{host}{path}"


def case_url(case_id):
    return app_url(f"/fd/cases/{case_id}")


def member_url(user_id):
    return app_url(f"/fd/members/{user_id}")


def gather(conn, case_id):
    row = conn.execute(CASE, (case_id,)).fetchone()
    if not row:
        return None
    case = {
        "case_id": row[0],
        "category_key": row[1],
        "resolved_at": row[2],
        "report_id": row[3],
        "is_anonymous": row[4],
        "reporter_user_id": row[5],
        "body": row[6],
        "forwarded_ts": row[7],
        "received_at": row[8],
        "conversation_id": row[9],
        "card_digest": row[10],
        "url": case_url(row[0]),
        "files": [],
        "shares": [],
        "message_id": None,
    }

    case["subjects"] = [
        subject[0] for subject in conn.execute(SUBJECTS, (case["case_id"],)).fetchall()
    ]
    case["assignees"] = [
        held[0] for held in conn.execute(ASSIGNEES, (case["case_id"],)).fetchall()
    ]
    case["other_cases"] = (
        conn.execute(OTHER_CASES, (case["case_id"], case["subjects"])).fetchone()[0]
        if case["subjects"]
        else 0
    )
    case["threads"] = conn.execute(THREADS, (case["case_id"],)).fetchone()[0]

    convo = case["conversation_id"]
    if convo is None:
        return case

    first = conn.execute(FIRST_MESSAGE, (convo,)).fetchone()
    if first:
        case["message_id"] = first[0]
        case["mirrored_ts"] = first[2]
        if not case["body"]:
            case["body"] = first[1]

    case["files"] = [
        {"slack_file_id": f[0], "name": f[1], "fetch_state": f[2], "external_url": f[3]}
        for f in conn.execute(FILES, (convo,)).fetchall()
    ]
    case["shares"] = [
        {
            "kind": s[0],
            "source_channel_id": s[1],
            "source_channel_name": s[2],
            "source_ts": s[3],
            "permalink": s[4],
            "is_reachable": s[5],
            "source_author_user_id": s[6],
            "source_body": s[7],
        }
        for s in conn.execute(SHARES, (convo,)).fetchall()
    ]
    return case


def post_report(client, conn, case_id, channel_id=None):
    case = gather(conn, case_id)
    if case is None:
        log.warning("nemo: case %s has no report to post", case_id)
        return None
    if case["forwarded_ts"]:
        log.info("nemo: case %s is already in the firehouse", case_id)
        return case["forwarded_ts"]

    built = cards.report.blocks(case)
    sent = client.chat_postMessage(
        channel=channel_id or firehouse_channel(),
        text=cards.report.fallback(case),
        blocks=built,
        metadata=cards.report.metadata(case),
        unfurl_links=False,
        unfurl_media=False,
    )
    ts = sent["ts"]

    conn.execute(
        "UPDATE fd.case_reports SET forwarded_ts = %s, card_digest = %s, "
        "card_rendered_at = now() WHERE id = %s AND forwarded_ts IS NULL",
        (ts, digest_of(built), case["report_id"]),
    )
    if case["message_id"] and not case.get("mirrored_ts"):
        conn.execute(
            "UPDATE fd.intake_messages SET mirrored_ts = %s, mirrored_at = now() "
            "WHERE id = %s AND mirrored_ts IS NULL",
            (ts, case["message_id"]),
        )
    if case["message_id"]:
        carry.share(client, conn, case["message_id"], channel_id or firehouse_channel(), ts)

    log.info("nemo: case %s posted to the firehouse at %s", case_id, ts)
    return ts


def as_reporter(client, anonymous, reporter_user_id):
    if anonymous or not reporter_user_id:
        return {"username": ANONYMOUS}

    seen = who.face(client, reporter_user_id)
    wearing = {"username": seen["name"]}
    if seen["icon"]:
        wearing["icon_url"] = seen["icon"]
    wearing["metadata"] = {
        "event_type": "nemo_message",
        "event_payload": {"source_user_id": reporter_user_id},
    }
    return wearing


def post_follow_up(client, conn, message_id, channel_id=None):
    row = conn.execute(FOLLOW_UP, (message_id,)).fetchone()
    if not row:
        return None
    body, mirrored, forwarded, _, anonymous, reporter = row
    if mirrored:
        return mirrored
    if not forwarded:
        log.warning("nemo: message %s has no card to hang under", message_id)
        return None

    sent = client.chat_postMessage(
        channel=channel_id or firehouse_channel(),
        thread_ts=forwarded,
        text=cards.report.to_member(body),
        unfurl_links=False,
        unfurl_media=False,
        **as_reporter(client, anonymous, reporter),
    )
    ts = sent["ts"]
    conn.execute(
        "UPDATE fd.intake_messages SET mirrored_ts = %s, mirrored_at = now() "
        "WHERE id = %s AND mirrored_ts IS NULL",
        (ts, message_id),
    )
    carry.share(client, conn, message_id, channel_id or firehouse_channel(), forwarded)

    log.info("nemo: message %s carried into the firehouse at %s", message_id, ts)
    return ts


def redraw(client, conn, case_id, channel_id=None):
    case = gather(conn, case_id)
    if case is None or not case["forwarded_ts"]:
        return None

    built = cards.report.blocks(case)
    fingerprint = digest_of(built)
    if fingerprint == case["card_digest"]:
        return case["forwarded_ts"]

    client.chat_update(
        channel=channel_id or firehouse_channel(),
        ts=case["forwarded_ts"],
        text=cards.report.fallback(case),
        blocks=built,
    )
    conn.execute(
        "UPDATE fd.case_reports SET card_digest = %s, card_rendered_at = now() WHERE id = %s",
        (fingerprint, case["report_id"]),
    )
    log.info("nemo: case %s redrawn", case_id)
    return case["forwarded_ts"]


def whisper(client, body, said):
    client.chat_postEphemeral(
        channel=body["channel"]["id"],
        user=body["user"]["id"],
        thread_ts=body["message"].get("thread_ts") or body["message"]["ts"],
        text=said,
    )


def claimed(conn, case_id, user_id):
    conn.execute(CLAIM, (case_id, user_id, user_id))
    audit.record(conn, "assignee", case_id, "claimed", user_id, after={"user_id": user_id})


OPEN_CASE = """
INSERT INTO fd.cases (opened_by, opened_at, source_app)
VALUES (%s, now(), %s)
RETURNING id
"""

OPEN_ABOUT = """
SELECT c.id FROM fd.cases c
JOIN fd.case_participants p ON p.case_id = c.id AND p.role = 'subject'
WHERE p.user_id = %s AND c.resolved_at IS NULL
ORDER BY c.opened_at
LIMIT 3
"""

MEMBER_NOTE = """
INSERT INTO fd.notes (subject_user_id, body, author) VALUES (%s, %s, %s) RETURNING id
"""

ADD_SUBJECT = """
INSERT INTO fd.case_participants (case_id, user_id, role)
VALUES (%s, %s, 'subject')
ON CONFLICT DO NOTHING
RETURNING user_id
"""

SET_CATEGORY = """
UPDATE fd.cases SET category_key = %s, updated_at = now()
WHERE id = %s AND category_key IS NULL
RETURNING category_key
"""

KEEP_NOTE = """
INSERT INTO fd.notes (case_id, body, author) VALUES (%s, %s, %s) RETURNING id
"""

HAND_BACK = """
DELETE FROM fd.case_assignees WHERE case_id = %s AND user_id = %s
RETURNING assigned_by
"""

REOPEN = """
UPDATE fd.cases
SET resolved_at = NULL, resolution = NULL, duplicate_of = NULL,
    followed_decision_id = NULL, updated_at = now()
WHERE id = %s AND resolved_at IS NOT NULL
RETURNING resolution
"""

CLEAR_ASSIGNEES = """
DELETE FROM fd.case_assignees WHERE case_id = %s RETURNING user_id
"""

LIVE_ACTIONS = """
SELECT target_user_id, type_key, expires_at, details FROM fd.actions
WHERE case_id = %s AND reversed_at IS NULL
ORDER BY performed_at, id
"""

OPEN_REPORTS = """
SELECT count(*) FROM fd.case_reports WHERE case_id = %s AND closed_at IS NULL
"""

RESOLVE = """
UPDATE fd.cases SET resolved_at = now(), resolution = %s, member_note = %s, updated_at = now()
WHERE id = %s AND resolved_at IS NULL
RETURNING resolved_at
"""

CLOSE_REPORTS = """
UPDATE fd.case_reports SET closed_at = now(), closed_by = %s
WHERE case_id = %s AND closed_at IS NULL
RETURNING id
"""

OPEN_CONVERSATION = """
SELECT id FROM fd.intake_conversations WHERE report_id = %s AND closed_at IS NULL
"""

TELL_THEM = """
INSERT INTO fd.intake_outbox (conversation_id, kind, body, requested_by)
VALUES (%s, 'outcome', %s, %s)
"""

LOG_ACTION = """
INSERT INTO fd.actions
    (case_id, type_key, target_user_id, decided_by, performed_by, performed_at,
     source_app, expires_at, details)
VALUES (%s, %s, %s, %s, %s, now(), %s, %s, %s)
RETURNING id, performed_at
"""


def add_subject(conn, case_id, user_id, by):
    row = conn.execute(ADD_SUBJECT, (case_id, user_id)).fetchone()
    if row is None:
        return False

    audit.record(
        conn, "participant", case_id, "attached", by,
        after={"user_id": user_id, "role": "subject"},
    )
    return True


def set_category(conn, case_id, key, by):
    row = conn.execute(SET_CATEGORY, (key, case_id)).fetchone()
    if row is None:
        return False

    audit.record(
        conn, "case", case_id, "categorised", by,
        before={"category_key": None}, after={"category_key": key},
    )
    return True


def keep_note(conn, case_id, body, by):
    note_id = conn.execute(KEEP_NOTE, (case_id, body, by)).fetchone()[0]
    audit.record(
        conn, "note", note_id, "noted", by,
        after={"case_id": case_id, "body": body},
    )
    return note_id


def hand_back(conn, case_id, user_id):
    row = conn.execute(HAND_BACK, (case_id, user_id)).fetchone()
    if row is None:
        return False

    audit.record(
        conn, "assignee", case_id, "unclaimed", user_id,
        before={"user_id": user_id, "assigned_by": row[0]},
    )
    return True


def reopen(conn, case_id, by):
    row = conn.execute(REOPEN, (case_id,)).fetchone()
    if row is None:
        return False

    held = [one[0] for one in conn.execute(CLEAR_ASSIGNEES, (case_id,)).fetchall()]
    audit.record(
        conn, "case", case_id, "reopened", by,
        before={"resolution": row[0], "assignees": held},
        after={"resolved_at": None, "resolution": None, "assignees": []},
    )
    return True


def said_again(client, conn, case_id, was, channel_id=None):
    redraw(client, conn, case_id, channel_id)

    case = gather(conn, case_id)
    if case is None or not case["forwarded_ts"]:
        return None

    said = was.replace("_", " ") if was else "resolved"
    return client.chat_postMessage(
        channel=channel_id or firehouse_channel(),
        thread_ts=case["forwarded_ts"],
        text=f":arrows_counterclockwise: they wrote back, so case {case_id} is open again "
        f"(it was closed as {said})",
        unfurl_links=False,
    )["ts"]


def open_about(conn, user_id):
    return [row[0] for row in conn.execute(OPEN_ABOUT, (user_id,)).fetchall()]


def open_case(conn, subject, body, by):
    case_id = conn.execute(OPEN_CASE, (by, audit.SOURCE_APP)).fetchone()[0]
    audit.record(conn, "case", case_id, "opened", by, after={"opened_by": by})
    add_subject(conn, case_id, subject, by)
    if body:
        keep_note(conn, case_id, body, by)
    return case_id


def member_note(conn, subject, body, by):
    note_id = conn.execute(MEMBER_NOTE, (subject, body, by)).fetchone()[0]
    audit.record(
        conn, "note", note_id, "noted", by,
        after={"subject_user_id": subject, "body": body},
    )
    return note_id


def counted(conn, sql, case_id):
    return conn.execute(sql, (case_id,)).fetchone()[0]


def live_actions(conn, case_id):
    return [
        {
            "target_user_id": row[0],
            "type_key": row[1],
            "expires_at": row[2],
            "details": row[3],
        }
        for row in conn.execute(LIVE_ACTIONS, (case_id,)).fetchall()
    ]


def close_reports(conn, case_id, said, user_id):
    told = 0
    for row in conn.execute(CLOSE_REPORTS, (user_id, case_id)).fetchall():
        report_id = row[0]
        audit.record(
            conn, "report", report_id, "closed", user_id,
            before={"closed_at": None}, after={"closed_at": "now", "case_id": case_id},
        )
        open_one = conn.execute(OPEN_CONVERSATION, (report_id,)).fetchone()
        if open_one is None:
            continue
        conn.execute(TELL_THEM, (open_one[0], said, user_id))
        told += 1
    return told


def resolve(conn, case_id, said, user_id):
    row = conn.execute(
        RESOLVE, (said["resolution"], said["member_note"], case_id)
    ).fetchone()
    if row is None:
        return None

    audit.record(
        conn, "case", case_id, "resolved", user_id,
        before={"resolved_at": None, "resolution": None},
        after={
            "resolved_at": str(row[0]),
            "resolution": said["resolution"],
            "member_note": said["member_note"],
        },
    )
    told = close_reports(conn, case_id, said["said"], user_id) if said["telling"] else 0
    return told


def log_action(conn, case_id, said, user_id):
    expires = f"{said['expires_on']} 23:59:59" if said.get("expires_on") else None
    row = conn.execute(
        LOG_ACTION,
        (
            case_id,
            said["type_key"],
            said["target_user_id"],
            user_id,
            user_id,
            audit.SOURCE_APP,
            expires,
            Jsonb(cards.action.details(said)),
        ),
    ).fetchone()

    audit.record(
        conn,
        "action",
        row[0],
        "performed",
        user_id,
        after={
            "case_id": case_id,
            "type_key": said["type_key"],
            "target_user_id": said["target_user_id"],
            "expires_at": expires,
        },
    )
    return row[0]


def echo(client, thread_ts, sent_by, body, signed, channel_id=None):
    seen = who.face(client, sent_by)
    wearing = {"username": seen["name"]}
    if seen["icon"]:
        wearing["icon_url"] = seen["icon"]
    wearing["metadata"] = {
        "event_type": "nemo_message",
        "event_payload": {"source_user_id": sent_by},
    }

    said = f"{answer.PREFIX}{cards.report.escape_but_mentions(body)}"
    if not signed:
        said = f"{answer.ANON}{said}"

    room = channel_id or firehouse_channel()
    try:
        sent = client.chat_postMessage(
            channel=room,
            thread_ts=thread_ts,
            text=said,
            unfurl_links=False,
            unfurl_media=False,
            **wearing,
        )
    except Exception as failure:
        log.warning("nemo: the thread did not hear about the reply: %s", failure)
        return None

    return room, sent["ts"]


def mirror(client, conn, case_id, channel_id=None):
    carried = 0

    for chat_id, author, body, thread_ts in chat.waiting(conn, case_id):
        seen = who.face(client, author)
        wearing = {"username": seen["name"]}
        if seen["icon"]:
            wearing["icon_url"] = seen["icon"]
        wearing["metadata"] = {
            "event_type": "nemo_message",
            "event_payload": {"source_user_id": author},
        }

        try:
            sent = client.chat_postMessage(
                channel=channel_id or firehouse_channel(),
                thread_ts=thread_ts,
                text=cards.report.escape_but_mentions(body),
                unfurl_links=False,
                unfurl_media=False,
                **wearing,
            )
        except Exception as failure:
            log.warning("nemo: chat %s did not reach the thread: %s", chat_id, failure)
            break

        chat.mirrored(conn, chat_id, sent["ts"])
        carried += 1

    if carried:
        log.info("nemo: carried %s message(s) into case %s's thread", carried, case_id)
    return carried


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

        client.views_open(
            trigger_id=body["trigger_id"],
            view=cards.action.view(case_id, subjects),
        )

    @app.view(cards.action.CALLBACK)
    def on_action_logged(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        said = cards.action.picked(view["state"])

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
        client.chat_postEphemeral(
            channel=firehouse_channel(),
            user=user_id,
            text=cards.action.told(said, case_id),
        )

    MORE = {
        cards.edit.SUBJECT: ("case.people", cards.edit.subject_view),
        cards.edit.CATEGORY: ("case.open", cards.edit.category_view),
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
        return whisper(client, body, f"you are off *case {case_id}*")

    @app.view(cards.edit.SUBJECT)
    def on_subject(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        wanted = cards.edit.who_picked(view["state"])

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.people", case_id)
            if not allowed:
                return ack(response_action="errors", errors={cards.edit.WHO: refusal})
            added = add_subject(conn, case_id, wanted, user_id)

        ack()
        with session() as conn:
            redraw(client, conn, case_id)
        log.info("nemo: case %s is about %s (new: %s)", case_id, wanted, added)
        client.chat_postEphemeral(
            channel=firehouse_channel(),
            user=user_id,
            text=(
                f"*case {case_id}* is about <@{wanted}>"
                if added
                else f"<@{wanted}> was already on *case {case_id}*"
            ),
        )
        return None

    @app.view(cards.edit.CATEGORY)
    def on_category(ack, body, view, client):
        case_id = int(view["private_metadata"])
        user_id = body["user"]["id"]
        key = cards.edit.what_picked(view["state"])

        with session() as conn:
            allowed, refusal = access.may(conn, user_id, "case.open", case_id)
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
        client.chat_postEphemeral(
            channel=firehouse_channel(),
            user=user_id,
            text=f"*case {case_id}* is {cards.edit.category_label(key).lower()}",
        )
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
        client.chat_postEphemeral(
            channel=firehouse_channel(),
            user=user_id,
            text=f"noted on *case {case_id}*",
        )
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
        return whisper(client, body, f"*case {case_id}* is open again, and unclaimed")

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
        client.chat_postEphemeral(
            channel=firehouse_channel(),
            user=user_id,
            text=cards.resolve.done(said, case_id, told),
        )

    @app.event("message")
    def on_message(event):
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
            return ours(event, thread_ts)

        if on_reply is None:
            return
        on_reply(
            thread_ts,
            aimed["said"],
            event.get("user"),
            signed=aimed["signed"],
            files=event.get("files") or [],
            at=(event["channel"], event["ts"]),
        )

    def ours(event, thread_ts):
        with session() as conn:
            case_id = chat.case_of_thread(conn, thread_ts)
            if case_id is None:
                return
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
