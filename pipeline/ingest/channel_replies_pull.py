import argparse

from dotenv import load_dotenv

from lib.db import connect, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from ingest import channel_history_pull as history
from ingest.channel_history_pull import (
    MESSAGE_SQL,
    OBSERVATION_SQL,
    message_row,
)

SOURCE = "channel_replies"
METHOD = "conversations.replies"
PAGE_SIZE = 999
TRANSPORT = "replies"

CLAIM_SQL = """
UPDATE app.channel_backfill
SET state = 'draining', claimed_at = now(), updated_at = now()
WHERE channel_id = (
    SELECT channel_id FROM app.channel_backfill
    WHERE state = 'queued'
    ORDER BY priority, requested_at
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
RETURNING channel_id
"""

RELEASE_STALE_SQL = """
UPDATE app.channel_backfill
SET state = 'queued', claimed_at = NULL, updated_at = now()
WHERE state = 'draining' AND claimed_at < now() - make_interval(hours => %s)
RETURNING channel_id
"""

PENDING_THREADS_SQL = """
SELECT root_ts, reply_count
FROM raw.thread
WHERE channel_id = %s AND replies_fetched < reply_count
ORDER BY root_ts DESC
LIMIT %s
"""

THREAD_DONE_SQL = """
UPDATE raw.thread
SET replies_fetched = %s, fetched_through_ts = %s, fetched_at = now()
WHERE channel_id = %s AND root_ts = %s
"""

PROGRESS_SQL = """
UPDATE app.channel_backfill SET
    threads_fetched = (SELECT count(*) FROM raw.thread
                       WHERE channel_id = %s AND replies_fetched >= reply_count),
    threads_expected = (SELECT count(*) FROM raw.thread WHERE channel_id = %s),
    replies_fetched = (SELECT coalesce(sum(replies_fetched), 0) FROM raw.thread
                       WHERE channel_id = %s),
    last_progress_at = now(),
    updated_at = now()
WHERE channel_id = %s
"""

SETTLE_SQL = """
UPDATE app.channel_backfill SET
    state = CASE WHEN %s THEN 'complete' ELSE 'queued' END,
    finished_at = CASE WHEN %s THEN now() ELSE NULL END,
    claimed_at = NULL,
    updated_at = now()
WHERE channel_id = %s AND state = 'draining'
"""


def fetch_thread(conn, client, channel_id, root_ts):
    rows, observations = [], []
    for message in client.paginate(
        METHOD, {"channel": channel_id, "ts": root_ts}, "messages",
        page_size=PAGE_SIZE, cursor_param="cursor", max_retries=8, credential="admin",
        page_param="limit", cursor_field="response_metadata.next_cursor",
    ):
        if message.get("ts") == root_ts:
            continue
        rows.append(message_row(channel_id, message))
        observations.append((channel_id, message["ts"], TRANSPORT))

    with conn.cursor() as cur:
        if rows:
            cur.executemany(MESSAGE_SQL, rows)
            cur.executemany(OBSERVATION_SQL, observations)
        cur.execute(THREAD_DONE_SQL,
            (len(rows), rows[-1][1] if rows else None, channel_id, root_ts))
    conn.commit()
    return len(rows)


WALKED_SQL = "SELECT 1 FROM raw.channel_walk WHERE channel_id = %s"

HOLD_SQL = """
UPDATE app.channel_backfill
SET state = 'queued', claimed_at = NULL, last_error = %s, updated_at = now()
WHERE channel_id = %s
"""


DRAINING_SQL = """
SELECT 1 FROM app.channel_backfill WHERE channel_id = %s AND state = 'draining'
"""


def walked(conn, channel_id):
    with conn.cursor() as cur:
        cur.execute(WALKED_SQL, (channel_id,))
        return cur.fetchone() is not None


def still_draining(conn, channel_id):
    with conn.cursor() as cur:
        cur.execute(DRAINING_SQL, (channel_id,))
        return cur.fetchone() is not None


def drain(conn, client, channel_id, budget):
    if not walked(conn, channel_id):
        print(f"{SOURCE}: {channel_id} has no history yet, walking it first")
        try:
            history.walk_channel(conn, client, channel_id, None)
        except Exception as exc:
            conn.rollback()
            with conn.cursor() as cur:
                cur.execute(HOLD_SQL, (f"history walk failed: {str(exc)[:200]}", channel_id))
            conn.commit()
            raise

    with conn.cursor() as cur:
        cur.execute(PENDING_THREADS_SQL, (channel_id, budget))
        threads = cur.fetchall()

    replies = 0
    walked_threads = 0
    for root_ts, _expected in threads:
        if not still_draining(conn, channel_id):
            print(f"{SOURCE}: {channel_id} was stopped, leaving it where it is")
            with conn.cursor() as cur:
                cur.execute(PROGRESS_SQL, (channel_id, channel_id, channel_id, channel_id))
            conn.commit()
            return walked_threads, replies, True
        replies += fetch_thread(conn, client, channel_id, root_ts)
        walked_threads += 1

    with conn.cursor() as cur:
        cur.execute(PROGRESS_SQL, (channel_id, channel_id, channel_id, channel_id))
        cur.execute(PENDING_THREADS_SQL, (channel_id, 1))
        done = not cur.fetchall()
        cur.execute(SETTLE_SQL, (done, done, channel_id))
    conn.commit()
    return walked_threads, replies, done


def claim(conn):
    with conn.cursor() as cur:
        cur.execute(CLAIM_SQL)
        row = cur.fetchone()
    conn.commit()
    return row[0] if row else None


def run(conn, budget=500, stale_hours=6):
    client = ProxyClient()
    with conn.cursor() as cur:
        cur.execute(RELEASE_STALE_SQL, (stale_hours,))
        for (stranded,) in cur.fetchall():
            print(f"{SOURCE}: returned stranded channel {stranded} to the queue")
    conn.commit()

    channel_id = claim(conn)
    if channel_id is None:
        print(f"{SOURCE}: nothing opted in")
        return 0

    total = 0
    with ingest_run(conn, SOURCE) as counts:
        remaining = budget
        while channel_id is not None and remaining > 0:
            threads, replies, done = drain(conn, client, channel_id, remaining)
            total += replies
            remaining -= max(threads, 1)
            counts.rows_in = total
            counts.progress()
            print(f"{SOURCE}: {channel_id} drained {threads} thread(s), {replies} replies, "
                  f"{'complete' if done else 'more to do'}")
            channel_id = claim(conn) if done else None

    print(f"{SOURCE}: {total} reply message(s) this run, {max(budget - remaining, 0)} "
          f"thread(s) of a {budget} budget")
    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--budget", type=int, default=500)
    args = parser.parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn, budget=args.budget)


if __name__ == "__main__":
    main()
