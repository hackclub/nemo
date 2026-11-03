import logging
import time

from slack_sdk.errors import SlackApiError

from bot.core import session
from bot.nemo import chat
from jobs import imported_chat
from lyla import link, status

log = logging.getLogger("chat_import")

BATCH = 50
PACE_SECONDS = 3.0
IDLE_SECONDS = 60
AGAIN_SECONDS = 3600
PAGE = 200
UNREADABLE = ("not_in_channel", "channel_not_found", "missing_scope", "access_denied")

WAITING = """
SELECT id FROM fd.cases
WHERE source_app = 'lyla' AND chat_imported_at IS NULL AND id <> ALL(%s)
ORDER BY resolved_at IS NOT NULL, opened_at DESC
LIMIT %s
"""

LEFT = "SELECT count(*) FROM fd.cases WHERE source_app = 'lyla' AND chat_imported_at IS NULL"

THREADS = """
SELECT card_channel_id, card_thread_ts FROM fd.cases
WHERE id = %(case_id)s AND card_channel_id IS NOT NULL AND card_thread_ts IS NOT NULL
UNION
SELECT channel_id, thread_ts FROM fd.case_threads WHERE case_id = %(case_id)s
UNION
SELECT card_channel_id, forwarded_ts FROM fd.case_reports
WHERE case_id = %(case_id)s AND forwarded_ts IS NOT NULL AND card_channel_id IS NOT NULL
"""

DONE = "UPDATE fd.cases SET chat_imported_at = now() WHERE id = %s AND chat_imported_at IS NULL"


def replies(client, channel_id, thread_ts):
    messages, cursor = [], None
    while True:
        response = client.conversations_replies(channel=channel_id, ts=thread_ts, cursor=cursor,
                                                limit=PAGE)
        messages += response.get("messages") or []
        cursor = ((response.get("response_metadata") or {}).get("next_cursor") or "").strip()
        time.sleep(PACE_SECONDS)
        if not cursor:
            return messages


def event_of(channel_id, message):
    return {
        "channel": channel_id,
        "ts": message["ts"],
        "thread_ts": message.get("thread_ts"),
        "user": message.get("user") or message.get("bot_id") or "unknown",
        "text": message.get("text") or "",
        "blocks": message.get("blocks"),
        "files": message.get("files") or [],
    }


_own = {}


def own_ids(client):
    if "ids" not in _own:
        identity = client.auth_test()
        _own["ids"] = {one for one in (identity.get("user_id"), identity.get("bot_id")) if one}
    return _own["ids"]


def import_case(client, case_id):
    with session() as conn:
        threads = conn.execute(THREADS, {"case_id": case_id}).fetchall()
    own = own_ids(client)
    stored = 0
    for channel_id, thread_ts in threads:
        messages = replies(client, channel_id, thread_ts)
        with session() as conn:
            report_id = imported_chat.report_for_thread(conn, channel_id, thread_ts)
            mirrors = imported_chat.known_mirrors(conn, [one["ts"] for one in messages if one.get("ts")])
            for message in messages:
                if imported_chat.classify(message, thread_ts, report_id, mirrors, own) == imported_chat.CHAT:
                    _chat_id, inserted = chat.insert(conn, case_id, event_of(channel_id, message))
                    stored += int(bool(inserted))
    with session() as conn:
        conn.execute(DONE, (case_id,))
    return stored


def sweep(client, waiting_retry):
    with session() as conn:
        case_ids = [row[0] for row in conn.execute(WAITING, (sorted(waiting_retry), BATCH)).fetchall()]
    done = 0
    for case_id in case_ids:
        try:
            stored = import_case(client, case_id)
        except SlackApiError as failure:
            error = (failure.response or {}).get("error", "")
            if error in UNREADABLE:
                log.info("chat import: case %s waits, Slack said %s", case_id, error)
            else:
                log.warning("chat import: case %s failed: %s", case_id, failure)
            waiting_retry.add(case_id)
            continue
        except Exception:
            log.exception("chat import: case %s failed", case_id)
            waiting_retry.add(case_id)
            continue
        done += 1
        log.info("chat import: case %s has its chat, %s message(s)", case_id, stored)
    return done, len(case_ids)


def left():
    with session() as conn:
        return conn.execute(LEFT).fetchone()[0]


def run(client):
    skipped = set()
    while True:
        _done, seen = sweep(client, skipped)
        if seen == 0:
            return left()


def ready():
    with session() as conn:
        return link.is_on(conn) and status.imported(conn)


def serve(client, stopping):
    while not stopping.is_set():
        try:
            if not (ready() and left()):
                stopping.wait(IDLE_SECONDS)
                continue
            remaining = run(client)
            log.info("chat import: pass done, %s case(s) without chat", remaining)
        except Exception:
            log.exception("chat import: the pass failed")
        stopping.wait(AGAIN_SECONDS)
