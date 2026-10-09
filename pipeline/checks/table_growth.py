from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE

SUBJECT = "table_growth"
WINDOW_DAYS = 30
FEWEST_DAYS = 7
TIMES_MEDIAN = 2
FLOOR_BYTES = 100 * 1024 * 1024

SNAPSHOT_SQL = """
INSERT INTO ingest.table_size (day, table_name, bytes, rows)
SELECT current_date, n.nspname || '.' || c.relname,
       sum(pg_total_relation_size(part.relid)),
       sum(greatest(leaf.reltuples, 0))::bigint
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL (
    SELECT relid FROM pg_partition_tree(c.oid) WHERE c.relkind = 'p'
    UNION ALL
    SELECT c.oid WHERE c.relkind <> 'p'
) part
JOIN pg_class leaf ON leaf.oid = part.relid
WHERE c.relkind IN ('r', 'p', 'm')
  AND NOT c.relispartition
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%%'
  AND n.nspname NOT LIKE 'pg_temp%%'
GROUP BY n.nspname, c.relname
ON CONFLICT (day, table_name) DO UPDATE SET
    bytes = EXCLUDED.bytes, rows = EXCLUDED.rows, measured_at = now()
"""

GROWTH_SQL = """
WITH history AS (
    SELECT table_name, day, bytes,
           (bytes - lag(bytes) OVER held) / nullif(day - lag(day) OVER held, 0) AS grew
    FROM ingest.table_size
    WHERE day >= current_date - %(window)s - 1
    WINDOW held AS (PARTITION BY table_name ORDER BY day)
)
SELECT today.table_name, today.bytes, today.grew,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY earlier.grew) AS median,
       count(earlier.grew) AS days
FROM history today
LEFT JOIN history earlier
       ON earlier.table_name = today.table_name AND earlier.day < today.day AND earlier.grew IS NOT NULL
WHERE today.day = current_date
GROUP BY today.table_name, today.bytes, today.grew
"""

MARK_SQL = """
UPDATE ingest.table_size
SET grew = %s, median_growth = %s, flagged = %s
WHERE day = current_date AND table_name = %s
"""

RECORD_SQL = """
INSERT INTO ingest.quality_result (run_id, subject, assertion, severity, status, observed, expected)
VALUES (%s, 'table_growth', %s, %s, %s, %s, %s)
"""


def limit(median):
    return max(TIMES_MEDIAN * max(median or 0, 0), FLOOR_BYTES)


def flagged(grew, median, days):
    return grew is not None and days >= FEWEST_DAYS and grew > limit(median)


def megabytes(value):
    return f"{value / (1024 * 1024):,.0f} MB"


def measure(conn):
    conn.execute(SNAPSHOT_SQL)
    rows = conn.execute(GROWTH_SQL, {"window": WINDOW_DAYS}).fetchall()
    marked = []
    for table, _bytes, grew, median, days in rows:
        median = round(median) if median is not None else None
        marked.append((grew, median, flagged(grew, median, days), table))
    with conn.cursor() as cur:
        cur.executemany(MARK_SQL, marked)
    return marked


def results(marked):
    loud = sorted((one for one in marked if one[2]), key=lambda one: -one[0])
    found = [(f"{table} grows under twice its {WINDOW_DAYS}-day median", "error", "fail",
              f"grew {megabytes(grew)} in a day", f"under {megabytes(limit(median))}")
             for grew, median, _flag, table in loud]
    found.append((f"no table grows past twice its {WINDOW_DAYS}-day median", "info",
                  "warn" if loud else "pass", f"{len(loud)} of {len(marked)} table(s) flagged", "0 flagged"))
    return found


def record(conn, run_id=None):
    found = results(measure(conn))
    with conn.cursor() as cur:
        for assertion, severity, status, observed, expected in found:
            cur.execute(RECORD_SQL, (run_id, assertion, severity, status, observed, expected))
    conn.commit()
    return found


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        found = record(conn)
    for assertion, _severity, status, observed, expected in found:
        print(f"{assertion:60} {status:4}  {observed}  (want {expected})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
