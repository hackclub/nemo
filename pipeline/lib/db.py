import contextvars
import json
import os
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass

import psycopg

STALE_AFTER_HOURS = 6

_step = contextvars.ContextVar("ingest_step", default=(None, None, None))


@contextmanager
def run_step(parent_run_id: int, step_index: int, step_total: int) -> Iterator[None]:
    token = _step.set((parent_run_id, step_index, step_total))
    try:
        yield
    finally:
        _step.reset(token)


def connect(dsn: str | None = None) -> psycopg.Connection:
    if dsn is not None:
        return psycopg.connect(dsn)
    return psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["PIPELINE_DB_USER"],
        password=os.environ["PIPELINE_DB_PASSWORD"],
    )


def connect_admin(dsn: str | None = None) -> psycopg.Connection:
    if dsn is not None:
        return psycopg.connect(dsn)
    return psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    )


def start_run(conn: psycopg.Connection, source: str) -> int:
    parent_run_id, step_index, step_total = _step.get()
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


@contextmanager
def ingest_run(conn: psycopg.Connection, source: str) -> Iterator[RunCounts]:
    run_id = start_run(conn, source)
    conn.commit()
    counts = RunCounts()
    try:
        yield counts
    except BaseException:
        conn.rollback()
        finish_run(conn, run_id, "failed", counts.rows_in, counts.rows_rejected)
        conn.commit()
        raise
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


def dead_letter(conn: psycopg.Connection, source: str, payload: dict, reason: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO raw.dead_letter (source, payload, reason) VALUES (%s, %s, %s)",
            (source, json.dumps(payload), reason),
        )
