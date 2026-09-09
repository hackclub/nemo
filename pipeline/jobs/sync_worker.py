import os
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timedelta

import psycopg
from dotenv import load_dotenv

from jobs.nightly_sync import (
    ENV_FILE,
    TABLES_ONLY,
    TRUTHY,
    credential_faults,
    run_dbt,
    run_sync,
    stage_plan,
)
from lib import settings
from lib.heartbeat import beating
from lib.proxy_client import ProxyClient
from lib.db import (
    beat,
    set_worker,
    STALE_AFTER_HOURS,
    SeededDeployment,
    cancel_scope,
    connect,
    refuse_if_seeded,
    sweep_stale_runs,
)

DEFAULT_AT = "03:00"
DEFAULT_POLL_SECONDS = 60
DEFAULT_TRANSFORM_SECONDS = 900
CANCEL_POLL_SECONDS = 30
BEAT_SECONDS = 60
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

RELEASE_STALE_SQL = """
UPDATE app.sync_request
SET status = 'failed', finished_at = now(), updated_at = now()
WHERE status IN ('claimed', 'cancelling')
  AND claimed_at < now() - make_interval(hours => %s)
RETURNING id
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


def reap():
    try:
        with connect() as conn, conn.cursor() as cur:
            swept = sweep_stale_runs(conn)
            cur.execute(RELEASE_STALE_SQL, (STALE_AFTER_HOURS,))
            stranded = [row[0] for row in cur.fetchall()]
            conn.commit()
    except psycopg.Error as exc:
        print(f"sync worker: reaper skipped after {type(exc).__name__}: {exc}")
        return
    for run_id, source in swept:
        print(f"sync worker: abandoned stale run {run_id} ({source})")
    for request_id in stranded:
        print(f"sync worker: failed stranded sync request {request_id}")


def scheduled_at():
    from_env = os.environ.get("NIGHTLY_AT", "").strip()
    try:
        with connect() as conn:
            return settings.run_at(conn)
    except Exception as exc:
        print(f"sync worker: reading the schedule failed, {type(exc).__name__}: {exc}")
        return from_env or DEFAULT_AT


def run_at_start_enabled():
    return os.environ.get("NIGHTLY_RUN_AT_START", "").strip().lower() in TRUTHY


WORKER = "sync_worker"


set_worker(WORKER)

PROXY_WORKER = "proxy"
VERIFY_EVERY_SECONDS = 300


def proxy_note():
    try:
        report = ProxyClient().verify()
    except Exception as exc:
        return f"FAILED unreachable, {type(exc).__name__}: {exc}"[:240]
    faults = credential_faults(report)
    if faults:
        return "FAILED " + "; ".join(faults)
    who = ", ".join(
        f"{name} {state.get('user')}" for name, state in (report.get("credentials") or {}).items()
    )
    pacing = ", ".join(
        f"{key.rsplit(':', 1)[-1]} {rate}/min"
        for key, rate in sorted((report.get("pacing") or {}).items())
    )
    build = (report.get("build") or {}).get("fingerprint")
    return (f"ok, {who}"
            + (f" | build {build}" if build else "")
            + (f" | {pacing}" if pacing else ""))


def probe_proxy(last_at):
    if time.monotonic() - last_at < VERIFY_EVERY_SECONDS:
        return last_at
    note = proxy_note()
    try:
        with connect() as conn:
            beat(conn, PROXY_WORKER, note)
    except Exception as exc:
        print(f"sync worker: proxy probe could not be recorded, {type(exc).__name__}: {exc}")
    if note.startswith("FAILED"):
        print(f"sync worker: proxy {note}")
    return time.monotonic()


def transform_every():
    return int(os.environ.get("TRANSFORM_EVERY_SECONDS", "") or DEFAULT_TRANSFORM_SECONDS)


def refresh_marts(last_at, state):
    every = transform_every()
    if every <= 0 or time.monotonic() - last_at < every:
        return last_at
    held = state["note"]
    state["note"] = "rebuilding the marts"
    try:
        with connect() as conn:
            run_dbt(conn, select=TABLES_ONLY)
    except Exception as exc:
        print(f"sync worker: mart refresh failed {type(exc).__name__}: {exc}")
    state["note"] = held
    return time.monotonic()


def waiting_note(scheduled):
    return f"next scheduled run at {scheduled:%Y-%m-%dT%H:%M}"


def run_scheduled(label="scheduled"):
    print(f"sync worker: {label} run starting at {datetime.now():%Y-%m-%dT%H:%M:%S}")
    try:
        run_id, status = run_sync()
        print(f"sync worker: {label} run {status}, run {run_id}")
    except Exception as exc:
        print(f"sync worker: {label} run failed {type(exc).__name__}: {exc}")


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        try:
            refuse_if_seeded(conn)
        except SeededDeployment as exc:
            print(f"sync worker: {exc}")
            raise SystemExit(1) from exc

    at = scheduled_at()
    poll = int(os.environ.get("SYNC_POLL_SECONDS", "") or DEFAULT_POLL_SECONDS)
    scheduled = next_run_at(at, datetime.now())
    print(
        f"sync worker: listening on {CHANNEL}, {poll}s fallback poll, "
        f"next scheduled run at {scheduled:%Y-%m-%dT%H:%M}"
    )
    waiting = listener()
    reap()
    state = {"note": waiting_note(scheduled)}
    probed = 0.0
    refreshed = 0.0

    with beating(WORKER, lambda: state["note"], every=BEAT_SECONDS):
        if run_at_start_enabled():
            state["note"] = "startup run"
            run_scheduled("startup")
            scheduled = next_run_at(at, datetime.now())
            print(f"sync worker: next scheduled run at {scheduled:%Y-%m-%dT%H:%M}")

        while True:
            probed = probe_proxy(probed)
            state["note"] = waiting_note(scheduled)
            refreshed = refresh_marts(refreshed, state)
            if datetime.now() >= scheduled:
                state["note"] = "scheduled run"
                run_scheduled()
                scheduled = next_run_at(at, datetime.now())
                print(f"sync worker: next scheduled run at {scheduled:%Y-%m-%dT%H:%M}")
                continue

            request = claim()
            if request:
                request_id, kind, stage = request
                state["note"] = f"sync request {request_id} ({stage or kind})"
                serve(*request)
                reap()
                continue

            try:
                if not wait_for_request(waiting, wait_seconds(poll, scheduled, datetime.now())):
                    reap()
            except psycopg.OperationalError as exc:
                print(f"sync worker: listener reconnecting after {type(exc).__name__}: {exc}")
                waiting = listener()


if __name__ == "__main__":
    main()
