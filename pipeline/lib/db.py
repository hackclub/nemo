import contextvars
import json
import os
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

import psycopg

STALE_AFTER_HOURS = 6

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


def start_run(conn: psycopg.Connection, source: str) -> int:
    parent_run_id, step_index, step_total = _step.get()
    if parent_run_id is None:
        for stale_id, stale_source in sweep_stale_runs(conn):
            print(f"abandoned stale run {stale_id} ({stale_source})")
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO raw.ingest_run (source, started_at, parent_run_id, step_index, step_total)
            VALUES (%s, clock_timestamp(), %s, %s, %s)
            RETURNING id
            """,
            (source, parent_run_id, step_index, step_total),
        )
        return cur.fetchone()[0]


def finish_run(conn: psycopg.Connection, run_id: int, status: str, rows_in: int, rows_rejected: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE raw.ingest_run
            SET finished_at = clock_timestamp(), status = %s, rows_in = %s, rows_rejected = %s
            WHERE id = %s
            """,
            (status, rows_in, rows_rejected, run_id),
        )


@dataclass
class RunCounts:
    rows_in: int = 0
    rows_rejected: int = 0
    total_expected: int | None = None
    run_id: int | None = None
    monitor: psycopg.Connection | None = None

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


@contextmanager
def ingest_run(conn: psycopg.Connection, source: str) -> Iterator[RunCounts]:
    run_id = start_run(conn, source)
    conn.commit()
    counts = RunCounts(run_id=run_id)
    try:
        yield counts
    except SyncCancelled:
        conn.rollback()
        finish_run(conn, run_id, "cancelled", counts.rows_in, counts.rows_rejected)
        conn.commit()
        raise
    except BaseException:
        conn.rollback()
        finish_run(conn, run_id, "failed", counts.rows_in, counts.rows_rejected)
        conn.commit()
        raise
    finally:
        counts.close()
    finish_run(conn, run_id, "ok", counts.rows_in, counts.rows_rejected)
    conn.commit()


def sweep_stale_runs(
    conn: psycopg.Connection, max_age_hours: int = STALE_AFTER_HOURS
) -> list[tuple[int, str]]:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE raw.ingest_run
            SET status = 'abandoned', finished_at = clock_timestamp()
            WHERE status = 'running'
              AND started_at < now() - make_interval(hours => %s)
            RETURNING id, source
            """,
            (max_age_hours,),
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
