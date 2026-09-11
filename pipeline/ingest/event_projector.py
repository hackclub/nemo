import argparse

from dotenv import load_dotenv

from lib import archive
from lib.db import connect, ingest_run
from lib.paths import ENV_FILE
from lib.task import per_entity

SOURCE = "event_projector"
TRANSPORT = "event"
METHOD = "event"
BATCH_LIMIT = 5000

PENDING_SQL = """
SELECT event_id, channel_id, ts, envelope, shape
FROM raw.event_delivery
WHERE projected_at IS NULL
ORDER BY received_at
LIMIT %s
"""

DONE_SQL = "UPDATE raw.event_delivery SET projected_at = now() WHERE event_id = ANY(%s)"


def project(conn, row, counts):
    event_id, channel_id, ts, envelope, measured = row
    if not channel_id or not ts or not isinstance(envelope, dict):
        counts.rows_rejected += 1
        return event_id

    if envelope.get("subtype") == archive.GONE:
        if archive.mark_deleted(conn, channel_id, ts, archive.stamp(envelope.get("event_ts"))):
            counts.rows_in += 1
        return event_id

    if archive.record(conn, channel_id, ts, envelope, measured, METHOD, TRANSPORT, False):
        counts.rows_in += 1
    return event_id


def pending(conn, limit):
    with conn.cursor() as cur:
        cur.execute(PENDING_SQL, (limit,))
        return cur.fetchall()


def run(conn, limit=BATCH_LIMIT):
    waiting = pending(conn, limit)
    if not waiting:
        print(f"{SOURCE}: nothing to project")
        return 0

    with ingest_run(conn, SOURCE) as counts:
        done = []
        for row in waiting:
            event_id, channel_id, ts = row[0], row[1], row[2]
            with per_entity(conn, SOURCE, counts,
                            {"event_id": str(event_id), "channel": channel_id, "ts": ts}):
                project(conn, row, counts)
                conn.commit()
            done.append(event_id)
        with conn.cursor() as cur:
            cur.execute(DONE_SQL, (done,))
        conn.commit()
    print(f"{SOURCE}: {counts.rows_in} message(s) projected from {len(done)} event(s), "
          f"{counts.rows_rejected} rejected")
    return len(done)


def main():
    load_dotenv(ENV_FILE)
    parser = argparse.ArgumentParser(prog=SOURCE)
    parser.add_argument("--limit", type=int, default=BATCH_LIMIT)
    asked = parser.parse_args()
    with connect() as conn:
        run(conn, asked.limit)


if __name__ == "__main__":
    main()
