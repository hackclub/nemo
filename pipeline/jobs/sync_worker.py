import os
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timedelta

import psycopg
from dotenv import load_dotenv

from jobs.nightly_sync import ENV_FILE, run_sync, stage_plan
from lib.db import cancel_scope, connect

DEFAULT_AT = "03:00"
DEFAULT_POLL_SECONDS = 60
CANCEL_POLL_SECONDS = 30
CHANNEL = "sync_request"
CANCEL_CHANNEL = "sync_cancel"

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


@contextmanager
def cancel_watcher(request_id):
    listener = connect()
    listener.autocommit = True
    listener.execute(f"LISTEN {CANCEL_CHANNEL}")
    state = {"checked_at": time.monotonic(), "cancelled": False}
    want = str(request_id)
    lock = threading.Lock()

    def check():
        with lock:
            if state["cancelled"]:
                return True
            try:
                for note in listener.notifies(timeout=0):
                    if note.payload == want:
                        state["cancelled"] = True
            except psycopg.Error:
                pass
            if state["cancelled"]:
                return True
            now = time.monotonic()
            if now - state["checked_at"] >= CANCEL_POLL_SECONDS:
                state["checked_at"] = now
                try:
                    with connect() as conn, conn.cursor() as cur:
                        cur.execute(
                            "SELECT status FROM app.sync_request WHERE id = %s", (request_id,)
                        )
                        row = cur.fetchone()
                    state["cancelled"] = bool(row and row[0] == "cancelling")
                except Exception:
                    pass
            return state["cancelled"]

    try:
        yield check
    finally:
        listener.close()


def serve(request_id, kind, stage):
    label = f"sync request {request_id} ({stage or kind})"
    print(f"{label}: starting")
    try:
        plan = stage_plan(stage) if kind == "stage" else None
        with cancel_watcher(request_id) as check, cancel_scope(check):
            run_id, status = run_sync(plan)
    except Exception as exc:
        print(f"{label}: worker failed {type(exc).__name__}: {exc}")
        release(request_id, "failed", None)
        return
    release(request_id, "cancelled" if status == "cancelled" else "done", run_id)
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
