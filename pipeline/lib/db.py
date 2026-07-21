import json
import os

import psycopg


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
    with conn.cursor() as cur:
        cur.execute("INSERT INTO raw.ingest_run (source) VALUES (%s) RETURNING id", (source,))
        return cur.fetchone()[0]


def finish_run(conn: psycopg.Connection, run_id: int, status: str, rows_in: int, rows_rejected: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE raw.ingest_run
            SET finished_at = now(), status = %s, rows_in = %s, rows_rejected = %s
            WHERE id = %s
            """,
            (status, rows_in, rows_rejected, run_id),
        )


def get_cursor(conn: psycopg.Connection, source: str, channel_id: str = "") -> str | None:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT cursor, status FROM raw.sync_cursor WHERE source = %s AND channel_id = %s",
            (source, channel_id),
        )
        row = cur.fetchone()
        if row and row[1] == "running":
            return row[0]
        return None


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


def dead_letter(conn: psycopg.Connection, source: str, payload: dict, reason: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO raw.dead_letter (source, payload, reason) VALUES (%s, %s, %s)",
            (source, json.dumps(payload), reason),
        )
