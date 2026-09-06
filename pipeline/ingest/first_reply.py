import argparse
import os
from datetime import datetime, timezone

from dotenv import load_dotenv

from lib import work
from lib.db import connect, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from lib.task import per_entity

SOURCE = "first_reply"
BATCH_LIMIT = int(os.environ.get("FIRST_REPLY_LIMIT", "4000"))
FLUSH_EVERY = 200
THREAD_PAGE = 20
THREAD_PAGES_MAX = 5
WALK_VERSION = 2

PERMANENT_ERRORS = ("team_access_not_granted", "channel_not_found", "thread_not_found", "message_not_found")

PENDING_BODY = """
SELECT h.user_id, h.first_post_channel, h.first_post_ts, r.user_id IS NOT NULL AS rewalk
FROM raw.member_message_history h
LEFT JOIN raw.member_first_reply r ON r.user_id = h.user_id
WHERE h.first_post_ts IS NOT NULL
  AND (r.user_id IS NULL OR r.walk_version < %s)
ORDER BY r.user_id IS NOT NULL, h.searched_at DESC, h.user_id
"""

PENDING_SQL = PENDING_BODY + "LIMIT %s"

KIND = "first_reply"

QUEUE_SELECT = f"""
SELECT p.user_id AS target_key, '' AS target_sub_key,
       CASE WHEN p.rewalk THEN 200 ELSE 100 END AS priority,
       jsonb_build_object('channel', p.first_post_channel, 'first_post_ts', p.first_post_ts) AS payload,
       NULL::integer AS expected
FROM ({PENDING_BODY.replace('%s', '%(p0)s')}) p
LEFT JOIN ingest.work_item w
       ON w.work_kind = '{KIND}' AND w.target_key = p.user_id AND w.target_sub_key = ''
WHERE w.work_item_id IS NULL OR w.state = 'short'
"""

MERGE_SQL = """
INSERT INTO raw.member_first_reply
    (user_id, replier_id, reply_ts, latency_seconds,
     bot_replier_id, bot_reply_ts, bot_latency_seconds,
     unreadable, reason, walk_version, fetched_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    replier_id = EXCLUDED.replier_id,
    reply_ts = EXCLUDED.reply_ts,
    latency_seconds = EXCLUDED.latency_seconds,
    bot_replier_id = EXCLUDED.bot_replier_id,
    bot_reply_ts = EXCLUDED.bot_reply_ts,
    bot_latency_seconds = EXCLUDED.bot_latency_seconds,
    unreadable = EXCLUDED.unreadable,
    reason = EXCLUDED.reason,
    walk_version = EXCLUDED.walk_version,
    fetched_at = now()
"""


def is_bot_message(message):
    return bool(message.get("bot_id")) or message.get("subtype") == "bot_message"


def scan_replies(user_id, first_post_ts, messages, bot_reply=None):
    for message in messages:
        replier = message.get("user") or message.get("bot_id")
        if not replier or replier == user_id:
            continue
        reply_ts = datetime.fromtimestamp(float(message["ts"]), tz=timezone.utc)
        latency = int((reply_ts - first_post_ts).total_seconds())
        if is_bot_message(message):
            bot_reply = bot_reply or (replier, reply_ts, latency)
            continue
        return (replier, reply_ts, latency), bot_reply
    return None, bot_reply


def reply_row(user_id, human_reply, bot_reply):
    return (
        user_id,
        *(human_reply or (None, None, None)),
        *(bot_reply or (None, None, None)),
        None,
        None,
        WALK_VERSION,
    )


def unreadable_row(user_id, reason):
    return (user_id, None, None, None, None, None, None, True, reason, WALK_VERSION)


def pending_members(conn, limit):
    with conn.cursor() as cur:
        cur.execute(PENDING_SQL, (WALK_VERSION, limit))
        return cur.fetchall()


def fetch_reply(client, user_id, channel, first_post_ts):
    ts = f"{first_post_ts.timestamp():.6f}"
    params = {"channel": channel, "ts": ts, "oldest": ts, "inclusive": True, "limit": THREAD_PAGE}
    human, bot = None, None

    for _ in range(THREAD_PAGES_MAX):
        resp = client.call("conversations.replies", params, credential="admin")
        human, bot = scan_replies(user_id, first_post_ts, resp.get("messages") or [], bot)
        cursor = (resp.get("response_metadata") or {}).get("next_cursor")
        if human or not resp.get("has_more") or not cursor:
            break
        params = {"channel": channel, "ts": ts, "limit": THREAD_PAGE, "cursor": cursor}

    return human, bot


def enqueue_pending(conn):
    return work.enqueue_select(conn, KIND, QUEUE_SELECT, (WALK_VERSION,), requested_by=SOURCE)


def post_of(item):
    return item.payload["channel"], datetime.fromisoformat(item.payload["first_post_ts"])


def run(conn, limit=BATCH_LIMIT):
    work.reclaim(conn, KIND)
    queued = enqueue_pending(conn)
    items = work.claim(conn, KIND, limit)
    if not items:
        print(f"{SOURCE}: every first post is checked, queue empty")
        return 0

    client = ProxyClient()
    print(f"{SOURCE}: {len(items)} first post(s) claimed off the queue"
          + (f", {queued} newly queued" if queued else ""))

    with ingest_run(conn, SOURCE) as counts:
        counts.total_expected = len(items)
        rows, done, unreadable = [], [], 0
        by_member, by_bot = 0, 0

        def flush():
            with conn.cursor() as cur:
                cur.executemany(MERGE_SQL, rows)
            work.settle_many(conn, done)
            conn.commit()
            rows.clear()
            done.clear()
            counts.progress()
            print(f"{SOURCE}: {counts.rows_in}/{len(items)} checked")

        for item in items:
            channel, first_post_ts = post_of(item)

            def unreadable_first_post(fault, item=item):
                nonlocal unreadable
                rows.append(unreadable_row(item.target_key, fault.detail))
                done.append((item, "unavailable", 0))
                counts.rows_in += 1
                unreadable += 1

            with per_entity(conn, SOURCE, counts, {"user_id": item.target_key, "channel": channel},
                            on_entity=unreadable_first_post,
                            on_fault=lambda fault, item=item: (
                                None if fault.name == "entity" else work.fail(conn, item, fault.detail))):
                human, bot = fetch_reply(client, item.target_key, channel, first_post_ts)
                rows.append(reply_row(item.target_key, human, bot))
                done.append((item, "complete", 1))
                counts.rows_in += 1
                by_member += 1 if human else 0
                by_bot += 1 if bot and not human else 0
            if len(rows) >= FLUSH_EVERY:
                flush()
        if rows or done:
            flush()

    if unreadable:
        print(f"{SOURCE}: {unreadable} first post(s) in unreadable channels, will not be retried")
    print(f"{SOURCE}: {by_member} answered by a member, {by_bot} by a bot only")
    print(f"{SOURCE}: {counts.rows_in} checked, {counts.rows_rejected} rejected")
    return len(items)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=BATCH_LIMIT)
    parser.add_argument("--burst", action="store_true")
    args = parser.parse_args()
    load_dotenv(ENV_FILE)

    with connect() as conn:
        if args.burst:
            while run(conn, args.limit):
                pass
        else:
            run(conn, args.limit)


if __name__ == "__main__":
    main()
