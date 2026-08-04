import os
import time
from datetime import datetime, timedelta

from dotenv import load_dotenv

from jobs.nightly_sync import ENV_FILE, run_sync, stage_plan
from lib.db import connect

DEFAULT_AT = "03:00"
DEFAULT_POLL_SECONDS = 15

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
    print(f"sync worker: polling every {poll}s, next scheduled run at {scheduled:%Y-%m-%dT%H:%M}")

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

        time.sleep(poll)


if __name__ == "__main__":
    main()
