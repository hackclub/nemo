import argparse
import os
from datetime import datetime, timezone

from dotenv import load_dotenv

from ingest.member_range_pull import SOURCE as MEMBER_RANGE_SOURCE
from lib import work
from lib.db import connect, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from lib.task import per_entity

SOURCE = "member_history"
BATCH_LIMIT = int(os.environ.get("MEMBER_HISTORY_LIMIT", "8000"))
FLUSH_EVERY = 200

PENDING_BODY = """
WITH horizon AS (
    SELECT max(account_created_verified) AS max_verified FROM raw.member_dim
),
range_activity AS (
    SELECT user_id, channel_messages_posted, window_start
    FROM raw.member_activity_snapshot
    WHERE source = %s
),
range_window AS (
    SELECT min(window_start) AS opened_at FROM range_activity
)
SELECT
    m.user_id,
    date_trunc('month', CASE
        WHEN coalesce(o.account_created_verified, m.account_created_verified) IS NOT NULL
            THEN coalesce(o.account_created_verified, m.account_created_verified)
        WHEN m.account_created > h.max_verified THEN m.account_created
    END)::date AS cohort_month
FROM raw.member_dim m
CROSS JOIN horizon h
CROSS JOIN range_window rw
LEFT JOIN raw.member_created_override o ON o.user_id = m.user_id
LEFT JOIN raw.member_message_history mh ON mh.user_id = m.user_id
LEFT JOIN range_activity r ON r.user_id = m.user_id
WHERE mh.user_id IS NULL
  AND NOT coalesce(m.is_bot, false)
  AND NOT coalesce(m.invite_pending, false)
  AND (r.user_id IS NULL
       OR coalesce(r.channel_messages_posted, 0) > 0
       OR coalesce(o.account_created_verified, m.account_created_verified) < rw.opened_at)
ORDER BY 2 DESC NULLS LAST, m.user_id
"""

PENDING_SQL = PENDING_BODY + "LIMIT %s"

KIND = "member_history"

QUEUE_SELECT = f"""
SELECT p.user_id AS target_key, '' AS target_sub_key,
       coalesce(current_date - p.cohort_month, 9999) AS priority,
       jsonb_build_object('cohort_month', p.cohort_month) AS payload,
       NULL::integer AS expected
FROM ({PENDING_BODY.replace('%s', '%(p0)s')}) p
LEFT JOIN ingest.work_item w
       ON w.work_kind = '{KIND}' AND w.target_key = p.user_id AND w.target_sub_key = ''
WHERE w.work_item_id IS NULL OR w.state IN ('short')
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


RANGE_SETTLE_SQL = """
WITH r AS (
    SELECT user_id, messages_posted, channel_messages_posted, window_start, window_end
    FROM raw.member_activity_snapshot
    WHERE source = %s
),
rw AS (
    SELECT min(window_start) AS opened_at, max(window_end) AS closed_at FROM r
)
INSERT INTO raw.member_message_history
    (user_id, total_messages, first_post_ts, first_post_channel, searched_at, counted_through)
SELECT m.user_id, coalesce(r.messages_posted, 0), NULL, NULL, now(), rw.closed_at
FROM raw.member_dim m
JOIN r ON r.user_id = m.user_id
LEFT JOIN raw.member_created_override o ON o.user_id = m.user_id
CROSS JOIN rw
WHERE NOT coalesce(m.is_bot, false)
  AND NOT coalesce(m.invite_pending, false)
  AND coalesce(r.channel_messages_posted, 0) = 0
  AND coalesce(o.account_created_verified, m.account_created_verified) >= rw.opened_at
ON CONFLICT (user_id) DO NOTHING
"""


def carry_forward(conn):
    with conn.cursor() as cur:
        cur.execute(CARRY_FORWARD_SQL)
        advanced = cur.rowcount
    conn.commit()
    print(f"{SOURCE}: {advanced} member(s) carried forward from daily rows")


def settle_from_range(conn):
    with conn.cursor() as cur:
        cur.execute(RANGE_SETTLE_SQL, (MEMBER_RANGE_SOURCE,))
        settled = cur.rowcount
    conn.commit()
    print(f"{SOURCE}: {settled} member(s) settled from the range, no search needed")


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
        cur.execute(PENDING_SQL, (MEMBER_RANGE_SOURCE, limit))
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


def enqueue_pending(conn):
    return work.enqueue_select(conn, KIND, QUEUE_SELECT, (MEMBER_RANGE_SOURCE,), requested_by=SOURCE)


def run(conn, limit=BATCH_LIMIT):
    settle_from_range(conn)
    carry_forward(conn)
    work.reclaim(conn, KIND)
    queued = enqueue_pending(conn)
    items = work.claim(conn, KIND, limit)
    if not items:
        print(f"{SOURCE}: every member is searched, queue empty")
        return 0

    client = ProxyClient.for_source(KIND)
    team_id = os.environ["SLACK_TEAM_ID"]
    print(f"{SOURCE}: {len(items)} member(s) claimed off the queue, newest cohorts first"
          + (f", {queued} newly queued" if queued else ""))

    with ingest_run(conn, SOURCE) as counts:
        counts.total_expected = len(items)
        rows, done = [], []

        def flush(month):
            with conn.cursor() as cur:
                cur.executemany(MERGE_SQL, rows)
            work.settle_many(conn, done)
            conn.commit()
            rows.clear()
            done.clear()
            counts.progress()
            label = str(month)[:7] if month else "unknown cohort"
            print(f"{SOURCE}: {counts.rows_in}/{len(items)} searched, through {label}")

        for item in items:
            with per_entity(conn, SOURCE, counts, {"user_id": item.target_key},
                            on_fault=lambda fault, item=item: work.fail(conn, item, fault.detail)):
                rows.append(search_member(client, team_id, item.target_key))
                done.append((item, "complete", 1))
                counts.rows_in += 1
            if len(rows) >= FLUSH_EVERY:
                flush(item.payload.get("cohort_month"))
        if rows or done:
            flush(items[-1].payload.get("cohort_month"))

    print(f"{SOURCE}: {counts.rows_in} searched, {counts.rows_rejected} rejected")
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
