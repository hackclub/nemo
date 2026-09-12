import re
import sys

from dotenv import load_dotenv

from lib import sources
from lib.db import CHANNEL_DAY, MEMBER_DAY, connect
from lib.paths import ENV_FILE

STATUSES = frozenset({"running", "ok", "failed", "skipped", "partial", "cancelled", "abandoned"})
COUNT_COLUMNS = (
    "rows_in", "rows_rejected", "total_expected", "pages", "rate_limited_ms",
    "expected", "landed", "fetched", "expected_count", "landed_count",
)
COUNT_TABLES = (("raw", "ingest_run"), ("ingest", "slice_coverage"), ("ingest", "work_item"))
DAY_LAG_LIMIT = 4
DAY_LEDGERS = (
    (MEMBER_DAY, sources.key_for_run("admin_analytics_api:member")),
    (CHANNEL_DAY, sources.key_for_run("admin_analytics_api:public_channel")),
)

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
        WHERE (table_schema, table_name) IN (SELECT * FROM unnest(%s::text[], %s::text[]))
          AND column_name = ANY(%s)
    """, ([schema for schema, _ in COUNT_TABLES],
          [table for _, table in COUNT_TABLES],
          list(COUNT_COLUMNS))).fetchall()
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


def i11_every_day_source_is_recent(conn):
    rows = conn.execute("""
        SELECT source, max(ds), (current_date - max(ds))::integer
        FROM raw.analytics_day
        GROUP BY source
        ORDER BY source
    """).fetchall()
    if not rows:
        return ("I11", "pass", "no day source has loaded yet", f"within {DAY_LAG_LIMIT} days")
    stale = [f"{source} stopped at {newest} ({behind}d)" for source, newest, behind in rows
             if behind > DAY_LAG_LIMIT]
    worst = max(behind for _, _, behind in rows)
    return ("I11", "fail" if stale else "pass",
            "; ".join(stale) if stale else f"{len(rows)} source(s), worst {worst}d behind",
            f"within {DAY_LAG_LIMIT} days")


def i12_the_day_ledgers_agree(conn):
    torn = []
    measured = 0
    for day_source, coverage_key in DAY_LEDGERS:
        era = conn.execute("""
            SELECT min(slice_key::date), max(slice_key::date)
            FROM ingest.slice_coverage
            WHERE source_key = %s AND slice_key ~ '^\\d{4}-\\d{2}-\\d{2}$'
        """, (coverage_key,)).fetchone()
        if era is None or era[0] is None:
            continue
        measured += 1
        loaded_without_slice, complete_without_day = conn.execute("""
            SELECT
                (SELECT count(*) FROM raw.analytics_day d
                  WHERE d.source IN (%(day)s, 'seed_' || %(day)s) AND d.loaded
                    AND d.ds BETWEEN %(from)s AND %(to)s
                    AND NOT EXISTS (
                        SELECT 1 FROM ingest.slice_coverage c
                        WHERE c.source_key = %(key)s AND c.slice_key = d.ds::text
                    )),
                (SELECT count(*) FROM ingest.slice_coverage c
                  WHERE c.source_key = %(key)s AND c.state = 'complete'
                    AND NOT EXISTS (
                        SELECT 1 FROM raw.analytics_day d
                        WHERE d.source IN (%(day)s, 'seed_' || %(day)s)
                          AND d.ds::text = c.slice_key AND d.loaded
                    ))
        """, {"day": day_source, "key": coverage_key, "from": era[0], "to": era[1]}).fetchone()
        if loaded_without_slice:
            torn.append(f"{day_source}: {loaded_without_slice} loaded day(s) with no slice")
        if complete_without_day:
            torn.append(f"{coverage_key}: {complete_without_day} complete slice(s) with no loaded day")
    if not measured:
        return ("I12", "pass", "no day source has claimed a slice yet", "both ledgers agree")
    return ("I12", "fail" if torn else "pass",
            "; ".join(torn) if torn else f"{measured} day source(s) agree across both ledgers",
            "every loaded day in the slice era has a slice, and every complete slice has a loaded day")


CHECKS = (
    i1_every_planned_stage_has_a_row,
    i4_counts_are_nullable,
    i10_status_vocabulary_matches_the_check,
    i11_every_day_source_is_recent,
    i12_the_day_ledgers_agree,
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
