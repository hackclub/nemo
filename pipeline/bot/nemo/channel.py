import logging
import os

from bot.nemo import cards

log = logging.getLogger("bot.nemo")

CASE = """
SELECT c.id, c.category_key,
       r.id, r.is_anonymous, r.reporter_user_id, r.body, r.forwarded_ts,
       v.id
FROM fd.cases c
JOIN fd.case_reports r ON r.case_id = c.id
LEFT JOIN fd.intake_conversations v ON v.report_id = r.id
WHERE c.id = %s
ORDER BY r.id
LIMIT 1
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
        "report_id": row[2],
        "is_anonymous": row[3],
        "reporter_user_id": row[4],
        "body": row[5],
        "forwarded_ts": row[6],
        "conversation_id": row[7],
        "url": case_url(row[0]),
        "files": [],
        "shares": [],
        "message_id": None,
    }

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

    sent = client.chat_postMessage(
        channel=channel_id or firehouse_channel(),
        text=cards.report.fallback(case),
        blocks=cards.report.blocks(case),
        unfurl_links=False,
        unfurl_media=False,
    )
    ts = sent["ts"]

    conn.execute(
        "UPDATE fd.case_reports SET forwarded_ts = %s WHERE id = %s AND forwarded_ts IS NULL",
        (ts, case["report_id"]),
    )
    if case["message_id"] and not case.get("mirrored_ts"):
        conn.execute(
            "UPDATE fd.intake_messages SET mirrored_ts = %s, mirrored_at = now() "
            "WHERE id = %s AND mirrored_ts IS NULL",
            (ts, case["message_id"]),
        )
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
    log.info("nemo: message %s carried into the firehouse at %s", message_id, ts)
    return ts


def register(app, on_reply=None):
    @app.event("message")
    def on_message(event):
        if on_reply is None:
            return
        if event.get("channel") != firehouse_channel():
            return
        if event.get("bot_id") or event.get("subtype"):
            return
        thread_ts = event.get("thread_ts")
        if not thread_ts or thread_ts == event.get("ts"):
            return
        on_reply(thread_ts, event.get("text"), event.get("user"))
