import contextvars
import json
import os
import time
import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

import psycopg

from lib import faults, settings, sources

STALE_AFTER_HOURS = 6
STALE_GRACE_HOURS = 2
RUN_SUSPECT_SECONDS = 300
REJECT_PARTIAL_AT = 0.10
WORKER_BOOT = str(uuid.uuid4())
_worker = "manual"


def set_worker(name: str) -> None:
    global _worker
    _worker = name


def worker() -> str:
    return _worker

_step = contextvars.ContextVar("ingest_step", default=(None, None, None))
_cancel = contextvars.ContextVar("cancel_check", default=None)


class SyncCancelled(RuntimeError):
    """A cancel was requested for the run in progress"""


def current_step() -> tuple:
    return _step.get()


def current_cancel():
    return _cancel.get()


@contextmanager
def run_step(parent_run_id: int, step_index: int, step_total: int) -> Iterator[None]:
    token = _step.set((parent_run_id, step_index, step_total))
    try:
        yield
    finally:
        _step.reset(token)


@contextmanager
def cancel_scope(check) -> Iterator[None]:
    token = _cancel.set(check)
    try:
        yield
    finally:
        _cancel.reset(token)


def raise_if_cancelled() -> None:
    check = _cancel.get()
    if check is not None and check():
        raise SyncCancelled("cancel requested")


def credentials(prefix: str) -> tuple[str, str]:
    return (
        os.environ.get(f"{prefix}_DB_USER") or os.environ["POSTGRES_USER"],
        os.environ.get(f"{prefix}_DB_PASSWORD") or os.environ["POSTGRES_PASSWORD"],
    )


def connect(dsn: str | None = None) -> psycopg.Connection:
    if dsn is not None:
        return psycopg.connect(dsn)
    user, password = credentials("PIPELINE")
    return psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        dbname=os.environ["POSTGRES_DB"],
        user=user,
        password=password,
    )


def connect_admin(dsn: str | None = None, maintenance: bool = False) -> psycopg.Connection:
    if dsn is not None:
        return psycopg.connect(dsn)
    return psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        dbname="postgres" if maintenance else os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    )


class SeededDeployment(RuntimeError):
    """The database holds synthetic data, so ingestion must not run against it"""


BEAT_SQL = """
INSERT INTO raw.worker_heartbeat (worker, beat_at, note, worker_boot)
VALUES (%s, now(), %s, %s::uuid)
ON CONFLICT (worker) DO UPDATE SET
    beat_at = now(), note = EXCLUDED.note, worker_boot = EXCLUDED.worker_boot
"""


def beat(conn: psycopg.Connection, name: str, note: str | None = None) -> None:
    boot = WORKER_BOOT if name == worker() else None
    try:
        conn.execute(BEAT_SQL, (name, note, boot))
        conn.commit()
    except psycopg.Error:
        conn.rollback()


def deployment_mode(conn: psycopg.Connection) -> str:
    row = conn.execute("SELECT mode FROM raw.deployment").fetchone()
    return row[0] if row else "live"


def refuse_if_seeded(conn: psycopg.Connection) -> None:
    mode = deployment_mode(conn)
    if mode != "live":
        raise SeededDeployment(
            f"{os.environ.get('POSTGRES_DB', 'this database')} is marked {mode}. "
            "ingestion would mix real Slack data into synthetic data and spend real "
            "API quota. rebuild the database if you meant to make it live"
        )


START_RUN_SQL = """
INSERT INTO raw.ingest_run
    (source, started_at, parent_run_id, step_index, step_total,
     source_key, logical_date, worker, worker_boot, stream_key, slice_key, attempt, parser_version)
VALUES
    (%(source)s, clock_timestamp(), %(parent)s, %(step_index)s, %(step_total)s,
     %(source_key)s,
     coalesce((SELECT logical_date FROM raw.ingest_run WHERE id = %(parent)s), current_date),
     %(worker)s, %(boot)s, %(stream_key)s, %(slice_key)s,
     CASE WHEN %(parent)s IS NULL THEN 1 ELSE 1 + (
         SELECT count(*) FROM raw.ingest_run
         WHERE parent_run_id = %(parent)s AND source_key = %(source_key)s
           AND stream_key IS NOT DISTINCT FROM %(stream_key)s
           AND slice_key IS NOT DISTINCT FROM %(slice_key)s) END,
     %(parser_version)s)
RETURNING id
"""


def start_run(
    conn: psycopg.Connection, source: str, stream_key: str | None = None, slice_key: str | None = None
) -> int:
    parent_run_id, step_index, step_total = _step.get()
    if parent_run_id is None:
        for stale_id, stale_source in sweep_stale_runs(conn):
            print(f"abandoned stale run {stale_id} ({stale_source})")
        for dead_id, dead_source in suspect_dead_runs(conn, reclaim_seconds=settings.reclaim_seconds(conn)):
            print(f"run {dead_id} ({dead_source}) has no heartbeat behind it")
    source_key = sources.key_for_run(source)
    with conn.cursor() as cur:
        cur.execute(START_RUN_SQL, {
            "source": source, "parent": parent_run_id, "step_index": step_index,
            "step_total": step_total, "source_key": source_key, "worker": worker(),
            "boot": WORKER_BOOT, "stream_key": stream_key, "slice_key": slice_key,
            "parser_version": sources.parser_version(source_key),
        })
        run_id = cur.fetchone()[0]
    return run_id


def finish_run(
    conn: psycopg.Connection, run_id: int, status: str, rows_in: int, rows_rejected: int,
    error_class: str | None = None, error_detail: str | None = None,
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE raw.ingest_run
            SET finished_at = clock_timestamp(), status = %s, rows_in = %s, rows_rejected = %s,
                error_class = %s, error_detail = %s
            WHERE id = %s
              AND (status = 'running'
                   OR (status = 'abandoned' AND worker = %s AND worker_boot = %s::uuid))
            """,
            (status, rows_in, rows_rejected, error_class, error_detail, run_id, worker(), WORKER_BOOT),
        )
        if cur.rowcount == 0:
            print(f"finish_run: run {run_id} was not running or was reclaimed by another owner, "
                  "its status was left alone")


SINGLETON_NAMESPACE = 8571


class AlreadyRunning(RuntimeError):
    pass


@contextmanager
def sole_instance(name: str):
    holder = connect()
    try:
        taken = holder.execute(
            "SELECT pg_try_advisory_lock(%s, hashtext(%s))",
            (SINGLETON_NAMESPACE, name),
        ).fetchone()[0]
        holder.commit()
        if not taken:
            raise AlreadyRunning(
                f"another {name} already holds the singleton lock on this database, "
                "so this one would double every in-process rate budget"
            )
        try:
            yield holder
        finally:
            holder.execute(
                "SELECT pg_advisory_unlock(%s, hashtext(%s))",
                (SINGLETON_NAMESPACE, name),
            )
            holder.commit()
    finally:
        holder.close()


BUILD_LOCK = "dbt-build"
BUILD_WAIT_SECONDS = 3600
BUILD_POLL_SECONDS = 5


def build_wait_seconds():
    return int(os.environ.get("NEMO_BUILD_WAIT_SECONDS", "") or BUILD_WAIT_SECONDS)


@contextmanager
def sole_build(wait_seconds=None, poll_seconds=BUILD_POLL_SECONDS,
               clock=time.monotonic, sleep=time.sleep):
    if wait_seconds is None:
        wait_seconds = build_wait_seconds()
    holder = connect()
    deadline = clock() + wait_seconds
    waited = False
    try:
        while True:
            taken = holder.execute(
                "SELECT pg_try_advisory_lock(%s, hashtext(%s))",
                (SINGLETON_NAMESPACE, BUILD_LOCK),
            ).fetchone()[0]
            holder.commit()
            if taken:
                if waited:
                    print(f"dbt: the {BUILD_LOCK} lock came free, building now")
                break
            if clock() >= deadline:
                raise AlreadyRunning(
                    f"another dbt build has held the {BUILD_LOCK} lock for more than "
                    f"{wait_seconds}s, and two builds race each other for the same relations"
                )
            if not waited:
                waited = True
                print(f"dbt: another build holds the {BUILD_LOCK} lock, waiting up to {wait_seconds}s")
            sleep(poll_seconds)
        try:
            yield holder
        finally:
            holder.execute(
                "SELECT pg_advisory_unlock(%s, hashtext(%s))",
                (SINGLETON_NAMESPACE, BUILD_LOCK),
            )
            holder.commit()
    finally:
        holder.close()


CLEAN_OUTCOMES = frozenset({"ok", "partial", "skipped"})


@dataclass
class RunCounts:
    rows_in: int = 0
    rows_rejected: int = 0
    total_expected: int | None = None
    run_id: int | None = None
    monitor: psycopg.Connection | None = None
    status: str = "ok"
    consecutive_faults: int = 0

    def progress(self) -> None:
        raise_if_cancelled()
        if self.run_id is None:
            return
        try:
            if self.monitor is None or self.monitor.closed:
                self.monitor = connect()
            with self.monitor.cursor() as cur:
                cur.execute(
                    """
                    UPDATE raw.ingest_run
                    SET rows_in = %s, rows_rejected = %s, total_expected = %s
                    WHERE id = %s
                    """,
                    (self.rows_in, self.rows_rejected, self.total_expected, self.run_id),
                )
            self.monitor.commit()
        except Exception:
            self.close()

    def close(self) -> None:
        if self.monitor is not None and not self.monitor.closed:
            self.monitor.close()
        self.monitor = None


def clean_outcome(counts: RunCounts) -> str:
    if counts.status in CLEAN_OUTCOMES and counts.status != "ok":
        return counts.status
    seen = counts.rows_in + counts.rows_rejected
    if counts.rows_rejected and seen and counts.rows_rejected / seen > REJECT_PARTIAL_AT:
        return "partial"
    return "ok"


@contextmanager
def ingest_run(
    conn: psycopg.Connection, source: str, benign=None,
    stream_key: str | None = None, slice_key: str | None = None,
) -> Iterator[RunCounts]:
    run_id = start_run(conn, source, stream_key=stream_key, slice_key=slice_key)
    conn.commit()
    counts = RunCounts(run_id=run_id)
    try:
        yield counts
    except SyncCancelled as exc:
        conn.rollback()
        finish_run(conn, run_id, "cancelled", counts.rows_in, counts.rows_rejected,
                   "cancelled", str(exc)[:500])
        conn.commit()
        raise
    except BaseException as exc:
        conn.rollback()
        status = "skipped" if benign and benign(exc) else "failed"
        fault = faults.classify(exc)
        finish_run(conn, run_id, status, counts.rows_in, counts.rows_rejected,
                   fault.name, fault.detail)
        conn.commit()
        raise
    finally:
        counts.close()
    finish_run(conn, run_id, clean_outcome(counts), counts.rows_in, counts.rows_rejected)
    conn.commit()


SUSPECT_SQL = """
UPDATE raw.ingest_run r
SET suspected_dead_at = now()
WHERE r.status = 'running' AND r.suspected_dead_at IS NULL
  AND r.worker_boot IS DISTINCT FROM %(boot)s::uuid
  AND NOT EXISTS (
      SELECT 1 FROM raw.worker_heartbeat h
      WHERE h.worker = r.worker
        AND h.beat_at >= now() - make_interval(secs => %(after)s)
        AND (h.worker_boot IS NULL OR h.worker_boot IS NOT DISTINCT FROM r.worker_boot))
RETURNING r.id, r.source
"""

REVIVE_SQL = """
UPDATE raw.ingest_run r
SET suspected_dead_at = NULL
FROM raw.worker_heartbeat h
WHERE r.status = 'running' AND r.suspected_dead_at IS NOT NULL AND r.worker = h.worker
  AND h.beat_at >= now() - make_interval(secs => %(after)s)
  AND (h.worker_boot IS NULL OR h.worker_boot IS NOT DISTINCT FROM r.worker_boot)
"""

MY_BEAT_IS_FRESH_SQL = """
SELECT 1 FROM raw.worker_heartbeat
WHERE worker = %s AND beat_at >= now() - make_interval(secs => %s)
"""


RECLAIM_SQL = """
UPDATE raw.ingest_run
SET status = 'abandoned',
    finished_at = suspected_dead_at + make_interval(secs => %s),
    error_class = 'local',
    error_detail = 'reclaimed, the worker stopped beating'
WHERE status = 'running'
  AND suspected_dead_at IS NOT NULL
  AND suspected_dead_at < now() - make_interval(secs => %s)
RETURNING id, source
"""


def suspect_dead_runs(
    conn: psycopg.Connection, after_seconds: int = RUN_SUSPECT_SECONDS, reclaim_seconds=None
) -> list[tuple[int, str]]:
    with conn.cursor() as cur:
        cur.execute(MY_BEAT_IS_FRESH_SQL, (worker(), after_seconds))
        if cur.fetchone() is None:
            return []
        cur.execute(REVIVE_SQL, {"after": after_seconds})
        cur.execute(SUSPECT_SQL, {"after": after_seconds, "boot": WORKER_BOOT})
        suspected = cur.fetchall()
        if reclaim_seconds is not None:
            cur.execute(RECLAIM_SQL, (reclaim_seconds, reclaim_seconds))
            for dead_id, dead_source in cur.fetchall():
                print(f"reclaimed run {dead_id} ({dead_source}), no heartbeat for {reclaim_seconds}s")
    conn.commit()
    return suspected


ORPHAN_SQL = """
UPDATE raw.ingest_run
SET status = 'abandoned', finished_at = clock_timestamp(),
    error_class = coalesce(error_class, 'local'),
    error_detail = coalesce(error_detail, %s)
WHERE status = 'running' AND worker = %s
  AND worker_boot IS DISTINCT FROM %s::uuid
RETURNING id, source
"""


def sweep_my_earlier_boots(conn: psycopg.Connection) -> list[tuple[int, str]]:
    gone = "swept: the worker restarted, so this run's process is gone"
    with conn.cursor() as cur:
        cur.execute(ORPHAN_SQL, (gone, worker(), WORKER_BOOT))
        orphans = cur.fetchall()
    conn.commit()
    return orphans


def stale_after_hours(conn: psycopg.Connection) -> int:
    budgeted = -(-settings.budget_minutes(conn) // 60)
    return max(STALE_AFTER_HOURS, budgeted + STALE_GRACE_HOURS)


def sweep_stale_runs(
    conn: psycopg.Connection, max_age_hours: int | None = None
) -> list[tuple[int, str]]:
    if max_age_hours is None:
        max_age_hours = stale_after_hours(conn)
    swept = f"swept: still running {max_age_hours} hours after it started, no worker claimed it"
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE raw.ingest_run
            SET status = 'abandoned', finished_at = clock_timestamp(),
                error_class = coalesce(error_class, 'local'),
                error_detail = coalesce(error_detail, %s)
            WHERE status = 'running'
              AND started_at < now() - make_interval(hours => %s)
            RETURNING id, source
            """,
            (swept, max_age_hours),
        )
        return cur.fetchall()


def get_cursor(
    conn: psycopg.Connection,
    source: str,
    channel_id: str = "",
    max_age_hours: int = STALE_AFTER_HOURS,
) -> str | None:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT cursor FROM raw.sync_cursor
            WHERE source = %s AND channel_id = %s AND status = 'running'
              AND updated_at > now() - make_interval(hours => %s)
            """,
            (source, channel_id, max_age_hours),
        )
        row = cur.fetchone()
        return row[0] if row else None


def save_cursor(conn: psycopg.Connection, source: str, cursor: str, channel_id: str = "") -> None:
    status = "running" if cursor else "done"
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO raw.sync_cursor (source, channel_id, cursor, status, updated_at)
            VALUES (%s, %s, %s, %s, now())
            ON CONFLICT (source, channel_id) DO UPDATE SET
                cursor = EXCLUDED.cursor,
                status = EXCLUDED.status,
                updated_at = now()
            """,
            (source, channel_id, cursor, status),
        )


def analyze(tables) -> str | None:
    refused = []
    try:
        with connect() as stats_conn:
            stats_conn.add_notice_handler(lambda note: refused.append(note.message_primary))
            for table in tables:
                stats_conn.execute(f"ANALYZE {table}")
    except Exception as exc:
        return f"{type(exc).__name__}: {exc}"
    return refused[0] if refused else None


def get_walk(
    conn: psycopg.Connection,
    source: str,
    window_key: str,
    max_age_hours: int = STALE_AFTER_HOURS,
) -> tuple[str | None, int]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT cursor, rows_seen FROM raw.sync_cursor
            WHERE source = %s AND channel_id = '' AND status = 'running'
              AND window_key = %s
              AND updated_at > now() - make_interval(hours => %s)
            """,
            (source, window_key, max_age_hours),
        )
        row = cur.fetchone()
        if row is None or not row[0]:
            return None, 0
        return row[0], row[1] or 0


def save_walk(
    conn: psycopg.Connection, source: str, window_key: str, cursor: str | None, rows_seen: int
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO raw.sync_cursor
                (source, channel_id, cursor, status, window_key, rows_seen, updated_at)
            VALUES (%s, '', %s, %s, %s, %s, now())
            ON CONFLICT (source, channel_id) DO UPDATE SET
                cursor = EXCLUDED.cursor,
                status = EXCLUDED.status,
                window_key = EXCLUDED.window_key,
                rows_seen = EXCLUDED.rows_seen,
                updated_at = now()
            """,
            (source, cursor or "", "running" if cursor else "done", window_key, rows_seen),
        )
    conn.commit()


MEMBER_DAY = "member_day"
CHANNEL_DAY = "channel_day"


def record_day(conn: psycopg.Connection, source: str, ds, rows_in: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO raw.analytics_day (source, ds, loaded, rows_in, updated_at)
            VALUES (%s, %s, %s, %s, now())
            ON CONFLICT (source, ds) DO UPDATE SET
                loaded = raw.analytics_day.loaded OR EXCLUDED.loaded,
                rows_in = EXCLUDED.rows_in,
                updated_at = now()
            """,
            (source, ds, rows_in > 0, rows_in),
        )


def mark_day_unavailable(conn: psycopg.Connection, source: str, ds, reason: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO raw.analytics_day (source, ds, loaded, unavailable, reason, updated_at)
            VALUES (%s, %s, false, true, %s, now())
            ON CONFLICT (source, ds) DO UPDATE SET
                unavailable = true,
                reason = EXCLUDED.reason,
                updated_at = now()
            """,
            (source, ds, reason),
        )


def dead_letter(conn: psycopg.Connection, source: str, payload: dict, reason: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO raw.dead_letter (source, payload, reason) VALUES (%s, %s, %s)",
            (source, json.dumps(payload), reason),
        )
