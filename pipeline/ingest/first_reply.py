import argparse
import os
import time
from datetime import datetime, timezone

from dotenv import load_dotenv

from lib.db import connect, dead_letter, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import InternalApiError, ProxyClient

SOURCE = "first_reply"
BATCH_LIMIT = int(os.environ.get("FIRST_REPLY_LIMIT", "4000"))
FLUSH_EVERY = 200
MIN_SECONDS_PER_FETCH = 1.2
THREAD_PAGE = 20
THREAD_PAGES_MAX = 5
WALK_VERSION = 2

PERMANENT_ERRORS = ("team_access_not_granted", "channel_not_found", "thread_not_found", "message_not_found")

PENDING_SQL = """
SELECT h.user_id, h.first_post_channel, h.first_post_ts, r.user_id IS NOT NULL AS rewalk
FROM raw.member_message_history h
LEFT JOIN raw.member_first_reply r ON r.user_id = h.user_id
WHERE h.first_post_ts IS NOT NULL
  AND (r.user_id IS NULL OR r.walk_version < %s)
ORDER BY r.user_id IS NOT NULL, h.searched_at DESC, h.user_id
LIMIT %s
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


def run(conn, limit=BATCH_LIMIT):
    members = pending_members(conn, limit)
    if not members:
        print(f"{SOURCE}: every first post is checked")
        return 0

    client = ProxyClient()
    rewalked = sum(1 for _, _, _, walked in members if walked)
    print(f"{SOURCE}: {len(members)} first post(s) to check, {rewalked} of them re-walked")

    with ingest_run(conn, SOURCE) as counts:
        counts.total_expected = len(members)
        rows, unreadable = [], 0
        by_member, by_bot = 0, 0

        def flush():
            with conn.cursor() as cur:
                cur.executemany(MERGE_SQL, rows)
            conn.commit()
            rows.clear()
            counts.progress()
            print(f"{SOURCE}: {counts.rows_in}/{len(members)} checked")

        for user_id, channel, first_post_ts, _ in members:
            started = time.monotonic()
            try:
                human, bot = fetch_reply(client, user_id, channel, first_post_ts)
                rows.append(reply_row(user_id, human, bot))
                counts.rows_in += 1
                by_member += 1 if human else 0
                by_bot += 1 if bot and not human else 0
            except InternalApiError as exc:
                if str(exc).startswith(PERMANENT_ERRORS):
                    rows.append(unreadable_row(user_id, str(exc)))
                    counts.rows_in += 1
                    unreadable += 1
                else:
                    counts.rows_rejected += 1
                    dead_letter(conn, SOURCE, {"user_id": user_id, "channel": channel}, str(exc))
            if len(rows) >= FLUSH_EVERY:
                flush()
            time.sleep(max(0.0, MIN_SECONDS_PER_FETCH - (time.monotonic() - started)))
        if rows:
            flush()

    if unreadable:
        print(f"{SOURCE}: {unreadable} first post(s) in unreadable channels, will not be retried")
    print(f"{SOURCE}: {by_member} answered by a member, {by_bot} by a bot only")
    print(f"{SOURCE}: {counts.rows_in} checked, {counts.rows_rejected} rejected")
    return len(members)


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
