import re
import sys

from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE

STATUSES = frozenset({"running", "ok", "failed", "skipped", "partial", "cancelled", "abandoned"})
COUNT_COLUMNS = (
    "rows_in", "rows_rejected", "total_expected", "pages", "rate_limited_ms",
    "expected", "landed", "fetched", "expected_count", "landed_count",
)
COUNT_TABLES = (("raw", "ingest_run"), ("ingest", "coverage"), ("ingest", "work_item"))

RECORD_SQL = """
INSERT INTO ingest.quality_result (run_id, subject, assertion, severity, status, observed, expected)
VALUES (%s, 'invariant', %s, %s, %s, %s, %s)
"""


def i1_every_planned_stage_has_a_row(conn):
    row = conn.execute("""
        SELECT p.logical_date,
               count(c.id) FILTER (WHERE c.step_index IS NOT NULL),
               max(c.step_total)
        FROM raw.ingest_run p
        LEFT JOIN raw.ingest_run c ON c.parent_run_id = p.id
        WHERE p.source = 'nightly_sync' AND p.status <> 'running'
        GROUP BY p.id, p.logical_date, p.started_at
        ORDER BY p.started_at DESC
        LIMIT 1
    """).fetchone()
    if row is None:
        return ("I1", "pass", "no completed nightly yet", "n/a")
    night, children, planned = row
    ok = planned is not None and children >= planned
    return ("I1", "pass" if ok else "fail", f"{children} stage rows on {night}", f"{planned} planned")


def i4_counts_are_nullable(conn):
    rows = conn.execute("""
        SELECT table_schema || '.' || table_name || '.' || column_name, is_nullable, column_default
        FROM information_schema.columns
        WHERE (table_schema, table_name) IN (('raw','ingest_run'), ('ingest','coverage'), ('ingest','work_item'))
          AND column_name = ANY(%s)
    """, (list(COUNT_COLUMNS),)).fetchall()
    bad = [name for name, nullable, default in rows if nullable == "NO" and default and "0" in default]
    return ("I4", "fail" if bad else "pass",
            ", ".join(bad) if bad else "every count column is nullable",
            "no count column is NOT NULL DEFAULT 0")


def i10_status_vocabulary_matches_the_check(conn):
    row = conn.execute(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ingest_run_status_ck'"
    ).fetchone()
    declared = frozenset(re.findall(r"'([a-z]+)'", row[0])) if row else frozenset()
    return ("I10", "pass" if declared == STATUSES else "fail",
            ",".join(sorted(declared)) or "no constraint", ",".join(sorted(STATUSES)))


def no_running_row_outlives_the_sweep(conn):
    count = conn.execute(
        "SELECT count(*) FROM raw.ingest_run WHERE status = 'running' AND started_at < now() - interval '6 hours'"
    ).fetchone()[0]
    return ("sweep", "pass" if count == 0 else "fail", f"{count} running row(s) older than 6h", "0")


def every_terminal_failure_is_classified(conn):
    count = conn.execute("""
        SELECT count(*) FROM raw.ingest_run
        WHERE status IN ('failed', 'abandoned', 'cancelled') AND error_class IS NULL
          AND started_at > now() - interval '1 day'
    """).fetchone()[0]
    return ("I3", "pass" if count == 0 else "fail", f"{count} unclassified failure(s) in 24h", "0")


CHECKS = (
    i1_every_planned_stage_has_a_row,
    i4_counts_are_nullable,
    i10_status_vocabulary_matches_the_check,
    no_running_row_outlives_the_sweep,
    every_terminal_failure_is_classified,
)


def severity_of(assertion, status):
    if status == "pass":
        return "info"
    return "warn" if assertion == "I4" else "error"


def record(conn, run_id=None):
    results = [check(conn) for check in CHECKS]
    with conn.cursor() as cur:
        for assertion, status, observed, expected in results:
            cur.execute(RECORD_SQL, (run_id, assertion, severity_of(assertion, status), status, observed, expected))
    conn.commit()
    return results


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        results = record(conn)
    for assertion, status, observed, expected in results:
        print(f"{assertion:5} {status:4}  {observed}  (want {expected})")
    return 1 if any(status == "fail" for _, status, _, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
