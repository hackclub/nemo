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


def dead_letter(conn: psycopg.Connection, source: str, payload: dict, reason: str) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO raw.dead_letter (source, payload, reason) VALUES (%s, %s, %s)",
            (source, json.dumps(payload), reason),
        )
