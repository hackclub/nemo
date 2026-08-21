import logging
import os

from bot.engine import access, audit, parse, session
from bot.nemo import answer, chat
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

SHARES = """
SELECT s.kind, s.source_channel_id, s.source_channel_name, s.source_ts, s.permalink
FROM fd.intake_shares s
JOIN fd.intake_messages m ON m.id = s.message_id
WHERE m.conversation_id = %s
ORDER BY m.posted_at, s.id
"""


FOLLOW_UP = """
SELECT m.body, m.mirrored_ts, r.forwarded_ts, m.conversation_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
LEFT JOIN fd.case_reports r ON r.id = c.report_id
WHERE m.id = %s
"""

COUNT_FILES = """
SELECT count(*) FROM fd.intake_message_files WHERE message_id = %s
"""

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


def case_url(case_id):
    host = os.environ.get("APP_HOST")
    if not host:
        return None
    scheme = "http" if host.startswith("localhost") or host.startswith("127.") else "https"
    return f"{scheme}://{host}/fd/cases/{case_id}"


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


def post_follow_up(client, conn, message_id, channel_id=None):
    row = conn.execute(FOLLOW_UP, (message_id,)).fetchone()
    if not row:
        return None
    body, mirrored, forwarded, _ = row
    if mirrored:
        return mirrored
    if not forwarded:
        log.warning("nemo: message %s has no card to hang under", message_id)
        return None

    files = conn.execute(COUNT_FILES, (message_id,)).fetchone()[0]
    sent = client.chat_postMessage(
        channel=channel_id or firehouse_channel(),
        thread_ts=forwarded,
        text=cards.report.follow_up(body, files),
        unfurl_links=False,
        unfurl_media=False,
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

        said = answer.meant_for_them(event.get("text"))
        if said is None:
            return ours(event, thread_ts)

        if on_reply is None:
            return
        on_reply(
            thread_ts,
            said,
            event.get("user"),
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
