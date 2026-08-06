import argparse
import os
import time
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect, dead_letter, ingest_run
from lib.proxy_client import InternalApiError, ProxyClient

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

SOURCE = "first_reply"
BATCH_LIMIT = int(os.environ.get("FIRST_REPLY_LIMIT", "4000"))
FLUSH_EVERY = 200
MIN_SECONDS_PER_FETCH = 1.2
THREAD_PAGE = 20

PERMANENT_ERRORS = ("team_access_not_granted", "channel_not_found", "thread_not_found", "message_not_found")

PENDING_SQL = """
SELECT h.user_id, h.first_post_channel, h.first_post_ts
FROM raw.member_message_history h
LEFT JOIN raw.member_first_reply r ON r.user_id = h.user_id
WHERE r.user_id IS NULL
  AND h.first_post_ts IS NOT NULL
ORDER BY h.searched_at DESC, h.user_id
LIMIT %s
"""

MERGE_SQL = """
INSERT INTO raw.member_first_reply
    (user_id, replier_id, reply_ts, latency_seconds, unreadable, reason, fetched_at)
VALUES (%s, %s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    replier_id = EXCLUDED.replier_id,
    reply_ts = EXCLUDED.reply_ts,
    latency_seconds = EXCLUDED.latency_seconds,
    unreadable = EXCLUDED.unreadable,
    reason = EXCLUDED.reason,
    fetched_at = now()
"""


def reply_row(user_id, first_post_ts, messages):
    for message in messages[1:]:
        replier = message.get("user")
        if not replier or replier == user_id:
            continue
        reply_ts = datetime.fromtimestamp(float(message["ts"]), tz=timezone.utc)
        return (
            user_id,
            replier,
            reply_ts,
            int((reply_ts - first_post_ts).total_seconds()),
            None,
            None,
        )
    return (user_id, None, None, None, None, None)


def unreadable_row(user_id, reason):
    return (user_id, None, None, None, True, reason)


def pending_members(conn, limit):
    with conn.cursor() as cur:
        cur.execute(PENDING_SQL, (limit,))
        return cur.fetchall()


def fetch_reply(client, user_id, channel, first_post_ts):
    resp = client.call(
        "conversations.replies",
        {
            "channel": channel,
            "ts": f"{first_post_ts.timestamp():.6f}",
            "limit": THREAD_PAGE,
        },
        credential="admin",
    )
    return reply_row(user_id, first_post_ts, resp.get("messages") or [])


def run(conn, limit=BATCH_LIMIT):
    members = pending_members(conn, limit)
    if not members:
        print(f"{SOURCE}: every first post is checked")
        return 0

    client = ProxyClient()
    print(f"{SOURCE}: {len(members)} first post(s) to check")

    with ingest_run(conn, SOURCE) as counts:
        counts.total_expected = len(members)
        rows, unreadable = [], 0

        def flush():
            with conn.cursor() as cur:
                cur.executemany(MERGE_SQL, rows)
            conn.commit()
            rows.clear()
            counts.progress()
            print(f"{SOURCE}: {counts.rows_in}/{len(members)} checked")

        for user_id, channel, first_post_ts in members:
            started = time.monotonic()
            try:
                rows.append(fetch_reply(client, user_id, channel, first_post_ts))
                counts.rows_in += 1
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
