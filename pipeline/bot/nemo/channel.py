import logging
import os

from bot.core import parse
from bot.core.wording import to_member
from bot.nemo import answer, cards, carry, channels, chat, who

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


LIVE_ACTION_COUNT = """
SELECT count(*) FROM fd.actions WHERE case_id = %s AND reversed_at IS NULL
"""


SHARES = """
SELECT s.kind, s.source_channel_id, s.source_channel_name, s.source_ts, s.permalink,
       s.is_reachable, s.source_author_user_id, s.source_body, s.raw
FROM fd.intake_shares s
WHERE s.message_id = %s
ORDER BY s.id
"""


CLAIM_CARD = """
SELECT forwarded_ts FROM fd.case_reports WHERE id = %s FOR UPDATE
"""


FOLLOW_UP = """
SELECT m.body, m.mirrored_ts, r.forwarded_ts, m.conversation_id,
       r.is_anonymous, r.reporter_user_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
LEFT JOIN fd.case_reports r ON r.id = c.report_id
WHERE m.id = %s
"""


ANONYMOUS = "Anonymous"


def digest_of(blocks):
    return parse.digest(None, blocks, None)


_firehouse = {}


def firehouse_channel(conn=None):
    if conn is not None:
        _firehouse["id"] = channels.setting(conn, channels.FIREHOUSE) or None
    return _firehouse.get("id") or os.environ["FIREHOUSE_CHANNEL_ID"]


def card_channel(case, channel_id=None, conn=None):
    return channel_id or firehouse_channel(conn)


CARD_ROOM = """
SELECT card_channel_id FROM fd.cases WHERE id = %(case_id)s
"""


def card_room(conn, case_id, channel_id=None):
    row = conn.execute(CARD_ROOM, {"case_id": case_id}).fetchone()
    return (row and row[0]) or channel_id or firehouse_channel(conn)


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


def channel_url(channel_id):
    return app_url(f"/fd/channels/{channel_id}")


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
    case["live_actions"] = conn.execute(LIVE_ACTION_COUNT, (case["case_id"],)).fetchone()[0]

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
            "raw": s[8],
        }
        for s in conn.execute(SHARES, (case["message_id"],)).fetchall()
    ]
    return case


def post_report(client, conn, case_id, channel_id=None, thread_ts=None):
    case = gather(conn, case_id)
    if case is None:
        log.warning("nemo: case %s has no report to post", case_id)
        return None
    if case["forwarded_ts"]:
        log.info("nemo: case %s is already in the firehouse", case_id)
        return case["forwarded_ts"]

    held = conn.execute(CLAIM_CARD, (case["report_id"],)).fetchone()
    if held and held[0]:
        log.info("nemo: case %s went up while we were asking, leaving it", case_id)
        return held[0]

    built = cards.report.blocks(case)
    room = channel_id or firehouse_channel(conn)
    sent = client.chat_postMessage(
        channel=room,
        thread_ts=thread_ts,
        text=cards.report.fallback(case),
        blocks=built,
        metadata=cards.report.metadata(case),
        unfurl_links=False,
        unfurl_media=False,
        **only_the_face(client, case["is_anonymous"], case["reporter_user_id"]),
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
        carry.share(
            client, conn, case["message_id"], room, ts,
            wearing=as_reporter(client, case["is_anonymous"], case["reporter_user_id"]),
        )

    log.info("nemo: case %s posted to the firehouse at %s", case_id, ts)
    return ts


def anonymous_face():
    told = os.environ.get("ANONYMOUS_ICON_URL")
    if told:
        return told

    host = os.environ.get("APP_HOST", "")
    if not host or host.startswith(("localhost", "127.")):
        return None
    return app_url("/anonymous.png")


def only_the_face(client, anonymous, reporter_user_id):
    worn = as_reporter(client, anonymous, reporter_user_id)
    worn.pop("metadata", None)
    return worn


def as_reporter(client, anonymous, reporter_user_id):
    if anonymous or not reporter_user_id:
        worn = {"username": ANONYMOUS}
        icon = anonymous_face()
        if icon:
            worn["icon_url"] = icon
        return worn

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

    ts = carry.share(
        client, conn, message_id, channel_id or firehouse_channel(conn), forwarded,
        wearing=as_reporter(client, anonymous, reporter),
        words=to_member(body),
    )
    if ts is None:
        log.info("nemo: message %s had nothing to carry", message_id)
        return None

    conn.execute(
        "UPDATE fd.intake_messages SET mirrored_ts = %s, mirrored_at = now() "
        "WHERE id = %s AND mirrored_ts IS NULL",
        (ts, message_id),
    )
    log.info("nemo: message %s carried into the firehouse at %s", message_id, ts)
    return ts


def redraw(client, conn, case_id, channel_id=None):
    case = gather(conn, case_id)
    if case is None:
        return None
    if not case["forwarded_ts"]:
        return post_report(client, conn, case_id, channel_id)

    built = cards.report.blocks(case)
    fingerprint = digest_of(built)
    if fingerprint == case["card_digest"]:
        return case["forwarded_ts"]

    try:
        client.chat_update(
            channel=card_channel(case, channel_id, conn),
            ts=case["forwarded_ts"],
            text=cards.report.fallback(case),
            blocks=built,
        )
    except Exception as failure:
        if not somebody_elses(failure):
            raise
        return recard(client, conn, case_id, case["report_id"], channel_id)

    conn.execute(
        "UPDATE fd.case_reports SET card_digest = %s, card_rendered_at = now() WHERE id = %s",
        (fingerprint, case["report_id"]),
    )
    log.info("nemo: case %s redrawn", case_id)
    return case["forwarded_ts"]


NOT_OURS = ("cant_update_message", "message_not_found", "edit_window_closed")


def somebody_elses(failure):
    said = str(failure)
    return any(one in said for one in NOT_OURS)


def recard(client, conn, case_id, report_id, channel_id):
    conn.execute(
        "UPDATE fd.case_reports SET forwarded_ts = NULL, card_digest = NULL WHERE id = %s",
        (report_id,),
    )
    log.info("nemo: case %s has a card we cannot edit, putting up a fresh one", case_id)
    return post_report(client, conn, case_id, channel_id)


def whisper(client, body, said):
    client.chat_postEphemeral(
        channel=body["channel"]["id"],
        user=body["user"]["id"],
        thread_ts=body["message"].get("thread_ts") or body["message"]["ts"],
        text=said,
    )


WOKE = """
SELECT woke_from FROM fd.cases
WHERE id = %s AND woke_at IS NOT NULL AND woke_told_at IS NULL
"""


WOKE_TOLD = """
UPDATE fd.cases SET woke_told_at = now() WHERE id = %s AND woke_told_at IS NULL
"""


WOKE_UNTOLD = """
SELECT id FROM fd.cases
WHERE woke_at IS NOT NULL AND woke_told_at IS NULL
ORDER BY woke_at LIMIT 50
"""


SOMETHING_TO_CARRY = """
coalesce(btrim(m.body), '') <> '' OR EXISTS (
    SELECT 1 FROM fd.intake_message_files mf
    JOIN fd.intake_files f ON f.id = mf.file_id
    WHERE mf.message_id = m.id AND mf.mirrored_at IS NULL
      AND f.fetch_state IN ('pending', 'stored')
)
"""

FOLLOW_UPS_WAITING = f"""
SELECT m.id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE r.case_id = %s AND m.direction = 'inbound' AND m.mirrored_ts IS NULL
  AND m.deleted_at IS NULL AND c.handed_off_at IS NOT NULL
  AND m.posted_at > c.handed_off_at AND ({SOMETHING_TO_CARRY})
ORDER BY m.posted_at, m.id
"""


FOLLOW_UPS_ANYWHERE = f"""
SELECT DISTINCT r.case_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE m.direction = 'inbound' AND m.mirrored_ts IS NULL AND m.deleted_at IS NULL
  AND c.handed_off_at IS NOT NULL AND m.posted_at > c.handed_off_at
  AND ({SOMETHING_TO_CARRY})
LIMIT 100
"""


FILES_WAITING = """
SELECT DISTINCT r.case_id
FROM fd.intake_message_files mf
JOIN fd.intake_files f ON f.id = mf.file_id
JOIN fd.intake_messages m ON m.id = mf.message_id
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE mf.mirrored_at IS NULL AND f.fetch_state = 'stored'
  AND m.direction = 'inbound' AND r.forwarded_ts IS NOT NULL
LIMIT 50
"""

FILES_ON_CASE = """
SELECT DISTINCT mf.message_id, r.forwarded_ts, r.is_anonymous, r.reporter_user_id
FROM fd.intake_message_files mf
JOIN fd.intake_files f ON f.id = mf.file_id
JOIN fd.intake_messages m ON m.id = mf.message_id
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE r.case_id = %s AND mf.mirrored_at IS NULL AND f.fetch_state = 'stored'
  AND m.direction = 'inbound' AND r.forwarded_ts IS NOT NULL
ORDER BY mf.message_id
"""


def waiting_files(conn):
    return [row[0] for row in conn.execute(FILES_WAITING).fetchall()]


def carry_files(client, conn, case_id, channel_id=None):
    sent = 0
    for message_id, forwarded_ts, anonymous, reporter in conn.execute(
        FILES_ON_CASE, (case_id,)
    ).fetchall():
        if carry.share(
            client, conn, message_id, channel_id or firehouse_channel(conn), forwarded_ts,
            wearing=as_reporter(client, anonymous, reporter),
        ):
            sent += 1
    return sent


def waiting_follow_ups(conn):
    return [row[0] for row in conn.execute(FOLLOW_UPS_ANYWHERE).fetchall()]


def untold_wakes(conn):
    return [row[0] for row in conn.execute(WOKE_UNTOLD).fetchall()]


def carry_follow_ups(client, conn, case_id, channel_id=None):
    carried = 0
    for (message_id,) in conn.execute(FOLLOW_UPS_WAITING, (case_id,)).fetchall():
        if post_follow_up(client, conn, message_id, channel_id):
            carried += 1
    return carried


def tell_the_wake(client, conn, case_id, channel_id=None):
    row = conn.execute(WOKE, (case_id,)).fetchone()
    if row is None:
        return None

    was = row[0]
    told = said_again(client, conn, case_id, was, channel_id)
    conn.execute(WOKE_TOLD, (case_id,))
    return told


def said_again(client, conn, case_id, was, channel_id=None):
    redraw(client, conn, case_id, channel_id)

    case = gather(conn, case_id)
    if case is None or not case["forwarded_ts"]:
        return None

    said = was.replace("_", " ") if was else "resolved"
    return client.chat_postMessage(
        channel=card_channel(case, channel_id, conn),
        thread_ts=case["forwarded_ts"],
        text=f":arrows_counterclockwise: they wrote back, so case {case_id} is open again "
        f"(it was closed as {said})",
        unfurl_links=False,
    )["ts"]


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
    room = card_room(conn, case_id, channel_id)
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
                channel=room,
                thread_ts=thread_ts,
                text=cards.report.escape_but_mentions(body),
                unfurl_links=False,
                unfurl_media=False,
                **wearing,
            )
        except Exception as failure:
            log.warning("nemo: chat %s did not reach the thread: %s", chat_id, failure)
            continue

        chat.mirrored(conn, chat_id, sent["ts"])
        carried += 1

    if carried:
        log.info("nemo: carried %s message(s) into case %s's thread", carried, case_id)
    return carried
