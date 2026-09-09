import argparse
import threading
import time
from queue import Empty, Queue

from dotenv import load_dotenv

from lib import archive, work
from lib.db import RunCounts, cancel_scope, connect, current_cancel, ingest_run
from lib.task import per_entity
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
DEFAULT_FETCHERS = 4
PROGRESS_SECONDS = 5

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


def fetch_thread(conn, client, channel_id, root_ts, item=None):
    rows, observations, kept = [], [], []
    total, through = 0, None

    def flush():
        nonlocal rows, observations, kept
        with conn.cursor() as cur:
            if rows:
                cur.executemany(MESSAGE_SQL, rows)
                cur.executemany(OBSERVATION_SQL, observations)
            cur.execute(THREAD_DONE_SQL, (total, through, channel_id, root_ts))
        archive.from_api_many(conn, channel_id, kept, METHOD, TRANSPORT)
        conn.commit()
        rows, observations, kept = [], [], []
        if item is not None:
            work.renew(conn, item)

    for message in client.paginate(
        METHOD, {"channel": channel_id, "ts": root_ts}, "messages",
        page_size=PAGE_SIZE, cursor_param="cursor", max_retries=8, credential="admin",
        page_param="limit", cursor_field="response_metadata.next_cursor",
    ):
        if message.get("ts") == root_ts:
            continue
        row = message_row(channel_id, message)
        rows.append(row)
        observations.append((channel_id, message["ts"], TRANSPORT))
        kept.append(message)
        total += 1
        through = row[1]
        if len(rows) >= PAGE_SIZE:
            flush()

    flush()
    return total


WALKED_SQL = "SELECT 1 FROM raw.channel_walk WHERE channel_id = %s"

HOLD_SQL = """
UPDATE app.channel_backfill
SET state = 'queued', claimed_at = NULL, last_error = %s, updated_at = now()
WHERE channel_id = %s
"""


DRAINING_SQL = """
SELECT 1
FROM app.channel_backfill
WHERE channel_id = %s AND state <> 'draining'
"""


def walked(conn, channel_id):
    with conn.cursor() as cur:
        cur.execute(WALKED_SQL, (channel_id,))
        return cur.fetchone() is not None


def still_draining(conn, channel_id):
    with conn.cursor() as cur:
        cur.execute(DRAINING_SQL, (channel_id,))
        return cur.fetchone() is None


KIND = "channel_replies"

THREAD_SELECT = """
SELECT t.channel_id AS target_key, t.root_ts AS target_sub_key,
       coalesce(b.priority, 1000 - least(t.reply_count, 999)) AS priority,
       '{}'::jsonb AS payload, t.reply_count AS expected
FROM raw.thread t
LEFT JOIN app.channel_backfill b
       ON b.channel_id = t.channel_id AND b.state = 'draining'
WHERE t.replies_fetched < t.reply_count
"""

OPEN_UNITS_SQL = """
SELECT 1 FROM ingest.work_item
WHERE work_kind = %s AND target_key = %s AND state IN ('pending', 'claimed')
LIMIT 1
"""


def prepare(conn, client, channel_id):
    if walked(conn, channel_id):
        return True
    queued = history.enqueue_backfill(conn, [channel_id], priority=0)
    print(f"{SOURCE}: {channel_id} has no history yet, backfill "
          + ("queued at the front" if queued else "already queued") + ", threads follow once it lands")
    return False


def claim_channels(conn):
    claimed = []
    while True:
        with conn.cursor() as cur:
            cur.execute(CLAIM_SQL)
            row = cur.fetchone()
        conn.commit()
        if row is None:
            return claimed
        claimed.append(row[0])


def settle_channel(conn, channel_id):
    with conn.cursor() as cur:
        cur.execute(PROGRESS_SQL, (channel_id, channel_id, channel_id, channel_id))
        cur.execute(OPEN_UNITS_SQL, (KIND, channel_id))
        done = cur.fetchone() is None
        if done:
            cur.execute(PENDING_THREADS_SQL, (channel_id, 1))
            done = not cur.fetchall()
        cur.execute(SETTLE_SQL, (done, done, channel_id))
    conn.commit()
    return done


def enqueue_threads(conn):
    return work.enqueue_select(conn, KIND, THREAD_SELECT, requested_by=SOURCE, requeue_when_grown=True)


def drain(client, pending, tally, guard, halt, broken, check):
    local = RunCounts()
    try:
        with connect() as conn, cancel_scope(check):
            while not halt.is_set():
                try:
                    item = pending.get_nowait()
                except Empty:
                    return
                channel_id, root_ts = item.target_key, item.sub_key
                if not still_draining(conn, channel_id):
                    work.release(conn, item)
                    continue
                rejected = local.rows_rejected
                with per_entity(conn, SOURCE, local, {"channel": channel_id, "root_ts": root_ts},
                                on_fault=lambda fault, item=item: work.fail(conn, item, fault.detail)):
                    work.renew(conn, item)
                    conn.commit()
                    replies = fetch_thread(conn, client, channel_id, root_ts, item)
                    reached = item.expected is None or replies >= item.expected
                    work.settle(conn, item, "complete" if reached else "short", fetched=replies,
                                note=None if reached else f"{replies} of {item.expected}")
                    conn.commit()
                    with guard:
                        tally["replies"] += replies
                        tally["touched"].add(channel_id)
                with guard:
                    tally["rejected"] += local.rows_rejected - rejected
    except BaseException as failure:
        broken.append(failure)
        halt.set()


def run(conn, budget=500, fetchers=DEFAULT_FETCHERS, stale_hours=6):
    client = ProxyClient.for_source(KIND)
    with conn.cursor() as cur:
        cur.execute(RELEASE_STALE_SQL, (stale_hours,))
        for (stranded,) in cur.fetchall():
            print(f"{SOURCE}: returned stranded channel {stranded} to the queue")
    conn.commit()

    for channel_id in claim_channels(conn):
        prepare(conn, client, channel_id)
    work.reclaim(conn, KIND)

    items = work.claim(conn, KIND, budget)
    queued = 0
    if len(items) < budget:
        queued = enqueue_threads(conn)
        items += work.claim(conn, KIND, budget - len(items))

    if not items:
        with ingest_run(conn, SOURCE):
            print(f"{SOURCE}: no thread waiting" + (f", {queued} newly queued" if queued else ""))
        return 0

    hands = max(1, min(fetchers, len(items)))
    print(f"{SOURCE}: {len(items)} thread(s) claimed off the queue of a {budget} budget"
          + (f", {queued} newly queued" if queued else "")
          + f", {hands} fetcher(s)")

    pending = Queue()
    for item in items:
        pending.put(item)
    tally = {"replies": 0, "rejected": 0, "touched": set()}
    guard, halt, broken = threading.Lock(), threading.Event(), []
    check = current_cancel()

    with ingest_run(conn, SOURCE) as counts:
        counts.total_expected = len(items)
        crew = [threading.Thread(target=drain, name=f"{SOURCE}-{hand}", daemon=True,
                                 args=(client, pending, tally, guard, halt, broken, check))
                for hand in range(hands)]
        for hand in crew:
            hand.start()
        try:
            while any(hand.is_alive() for hand in crew):
                with guard:
                    counts.rows_in, counts.rows_rejected = tally["replies"], tally["rejected"]
                counts.progress()
                time.sleep(PROGRESS_SECONDS)
        except BaseException:
            halt.set()
            raise
        finally:
            for hand in crew:
                hand.join()
        if broken:
            raise broken[0]
        with guard:
            counts.rows_in, counts.rows_rejected = tally["replies"], tally["rejected"]
        for channel_id in sorted(tally["touched"]):
            done = settle_channel(conn, channel_id)
            print(f"{SOURCE}: {channel_id} {'complete' if done else 'still draining'}")
        counts.progress()

    print(f"{SOURCE}: {tally['replies']} reply message(s) over {len(items)} thread(s)")
    return tally["replies"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--budget", type=int, default=500)
    parser.add_argument("--fetchers", type=int, default=DEFAULT_FETCHERS)
    args = parser.parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn, budget=args.budget, fetchers=args.fetchers)


if __name__ == "__main__":
    main()
