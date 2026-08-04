import os
from datetime import datetime, timedelta

import psycopg
from dotenv import load_dotenv

from jobs.nightly_sync import ENV_FILE, run_sync, stage_plan
from lib.db import connect

DEFAULT_AT = "03:00"
DEFAULT_POLL_SECONDS = 60
CHANNEL = "sync_request"

CLAIM_SQL = """
UPDATE app.sync_request
SET status = 'claimed', claimed_at = now(), updated_at = now()
WHERE id = (
    SELECT id FROM app.sync_request
    WHERE status = 'queued'
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
RETURNING id, kind, stage
"""

RELEASE_SQL = """
UPDATE app.sync_request
SET status = %s, run_id = %s, finished_at = now(), updated_at = now()
WHERE id = %s
"""


def next_run_at(at, now):
    hour, minute = (int(part) for part in at.split(":", 1))
    scheduled = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    return scheduled if scheduled > now else scheduled + timedelta(days=1)


def wait_seconds(poll, scheduled, now):
    return max(1.0, min(float(poll), (scheduled - now).total_seconds()))


def listener():
    conn = connect()
    conn.autocommit = True
    conn.execute(f"LISTEN {CHANNEL}")
    return conn


def wait_for_request(conn, timeout):
    for _ in conn.notifies(timeout=timeout, stop_after=1):
        return True
    return False


def claim():
    with connect() as conn, conn.cursor() as cur:
        cur.execute(CLAIM_SQL)
        row = cur.fetchone()
        conn.commit()
        return row


def release(request_id, status, run_id):
    with connect() as conn, conn.cursor() as cur:
        cur.execute(RELEASE_SQL, (status, run_id, request_id))
        conn.commit()


def serve(request_id, kind, stage):
    label = f"sync request {request_id} ({stage or kind})"
    print(f"{label}: starting")
    try:
        plan = stage_plan(stage) if kind == "stage" else None
        run_id, status = run_sync(plan)
    except Exception as exc:
        print(f"{label}: worker failed {type(exc).__name__}: {exc}")
        release(request_id, "failed", None)
        return
    release(request_id, "done", run_id)
    print(f"{label}: {status}, run {run_id}")


def run_scheduled():
    print(f"sync worker: scheduled run starting at {datetime.now():%Y-%m-%dT%H:%M:%S}")
    try:
        run_id, status = run_sync()
        print(f"sync worker: scheduled run {status}, run {run_id}")
    except Exception as exc:
        print(f"sync worker: scheduled run failed {type(exc).__name__}: {exc}")


def main():
    load_dotenv(ENV_FILE)
    at = os.environ.get("NIGHTLY_AT", "").strip() or DEFAULT_AT
    poll = int(os.environ.get("SYNC_POLL_SECONDS", "") or DEFAULT_POLL_SECONDS)
    scheduled = next_run_at(at, datetime.now())
    print(
        f"sync worker: listening on {CHANNEL}, {poll}s fallback poll, "
        f"next scheduled run at {scheduled:%Y-%m-%dT%H:%M}"
    )
    waiting = listener()

    while True:
        if datetime.now() >= scheduled:
            run_scheduled()
            scheduled = next_run_at(at, datetime.now())
            print(f"sync worker: next scheduled run at {scheduled:%Y-%m-%dT%H:%M}")
            continue

        request = claim()
        if request:
            serve(*request)
            continue

        try:
            wait_for_request(waiting, wait_seconds(poll, scheduled, datetime.now()))
        except psycopg.OperationalError as exc:
            print(f"sync worker: listener reconnecting after {type(exc).__name__}: {exc}")
            waiting = listener()


if __name__ == "__main__":
    main()
