import argparse
import os
import time
from datetime import datetime, timezone

from dotenv import load_dotenv

from lib.db import connect, dead_letter, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import InternalApiError, ProxyClient

SOURCE = "member_history"
BATCH_LIMIT = int(os.environ.get("MEMBER_HISTORY_LIMIT", "8000"))
FLUSH_EVERY = 200
MIN_SECONDS_PER_SEARCH = 0.6

PENDING_SQL = """
WITH horizon AS (
    SELECT max(account_created_verified) AS max_verified FROM raw.member_dim
)
SELECT
    m.user_id,
    date_trunc('month', CASE
        WHEN m.account_created_verified IS NOT NULL THEN m.account_created_verified
        WHEN m.account_created > h.max_verified THEN m.account_created
    END)::date AS cohort_month
FROM raw.member_dim m
CROSS JOIN horizon h
LEFT JOIN raw.member_message_history mh ON mh.user_id = m.user_id
WHERE mh.user_id IS NULL
  AND NOT coalesce(m.is_bot, false)
  AND NOT coalesce(m.invite_pending, false)
ORDER BY 2 DESC NULLS LAST, m.user_id
LIMIT %s
"""

MERGE_SQL = """
INSERT INTO raw.member_message_history
    (user_id, total_messages, first_post_ts, first_post_channel, searched_at, counted_through)
VALUES (%s, %s, %s, %s, now(), now()::date)
ON CONFLICT (user_id) DO UPDATE SET
    total_messages = EXCLUDED.total_messages,
    first_post_ts = EXCLUDED.first_post_ts,
    first_post_channel = EXCLUDED.first_post_channel,
    searched_at = now(),
    counted_through = now()::date
"""

CARRY_FORWARD_SQL = """
WITH delta AS (
    SELECT s.user_id, sum(s.messages_posted) AS more, max(s.window_start) AS through
    FROM raw.member_activity_snapshot s
    JOIN raw.member_message_history h ON h.user_id = s.user_id
    WHERE s.window_start = s.window_end
      AND s.window_start > h.counted_through
    GROUP BY s.user_id
)
UPDATE raw.member_message_history h
SET total_messages = h.total_messages + delta.more,
    counted_through = delta.through
FROM delta
WHERE h.user_id = delta.user_id
"""


def carry_forward(conn):
    with conn.cursor() as cur:
        cur.execute(CARRY_FORWARD_SQL)
        advanced = cur.rowcount
    conn.commit()
    print(f"{SOURCE}: {advanced} member(s) carried forward from daily rows")


def is_public(match):
    channel = match.get("channel") or {}
    return not (channel.get("is_im") or channel.get("is_mpim") or channel.get("is_private"))


def history_row(user_id, messages):
    total = messages.get("total", 0)
    matches = messages.get("matches") or []
    first = next((match for match in matches if is_public(match)), None) if total else None
    if first is None:
        return (user_id, total, None, None)
    return (
        user_id,
        total,
        datetime.fromtimestamp(float(first["ts"]), tz=timezone.utc),
        first["channel"]["id"],
    )


def pending_members(conn, limit):
    with conn.cursor() as cur:
        cur.execute(PENDING_SQL, (limit,))
        return cur.fetchall()


def search_member(client, team_id, user_id):
    resp = client.call(
        "search.messages",
        {
            "query": f"from:<@{user_id}>",
            "sort": "timestamp",
            "sort_dir": "asc",
            "count": 1,
            "team_id": team_id,
        },
        credential="admin",
    )
    return history_row(user_id, resp.get("messages") or {})


def run(conn, limit=BATCH_LIMIT):
    carry_forward(conn)
    members = pending_members(conn, limit)
    if not members:
        print(f"{SOURCE}: every member is searched")
        return 0

    client = ProxyClient()
    team_id = os.environ["SLACK_TEAM_ID"]
    print(f"{SOURCE}: {len(members)} unsearched member(s), newest cohorts first")

    with ingest_run(conn, SOURCE) as counts:
        counts.total_expected = len(members)
        rows = []

        def flush(month):
            with conn.cursor() as cur:
                cur.executemany(MERGE_SQL, rows)
            conn.commit()
            rows.clear()
            counts.progress()
            label = month.strftime("%Y-%m") if month else "unknown cohort"
            print(f"{SOURCE}: {counts.rows_in}/{len(members)} searched, through {label}")

        for user_id, cohort_month in members:
            started = time.monotonic()
            try:
                rows.append(search_member(client, team_id, user_id))
                counts.rows_in += 1
            except (InternalApiError, KeyError, ValueError, TypeError) as exc:
                counts.rows_rejected += 1
                dead_letter(conn, SOURCE, {"user_id": user_id}, str(exc))
            if len(rows) >= FLUSH_EVERY:
                flush(cohort_month)
            time.sleep(max(0.0, MIN_SECONDS_PER_SEARCH - (time.monotonic() - started)))
        if rows:
            flush(members[-1][1])

    print(f"{SOURCE}: {counts.rows_in} searched, {counts.rows_rejected} rejected")
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
