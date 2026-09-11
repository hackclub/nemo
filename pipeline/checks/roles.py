from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE

SUBJECT = "roles"
EXPECTED_ROLES = ("pipeline_writer", "dbt_owner", "rails_app")

RECORD_SQL = """
INSERT INTO ingest.quality_result (run_id, subject, assertion, severity, status, observed, expected)
VALUES (%s, 'roles', %s, %s, %s, %s, %s)
"""

READABLE_SQL = """
SELECT count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = %s AND c.relkind IN ('r', 'p', 'v', 'm')
  AND has_table_privilege(%s, c.oid, 'SELECT')
"""

WRITABLE_SQL = """
SELECT count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = %s AND c.relkind IN ('r', 'p', 'v', 'm')
  AND has_table_privilege(%s, c.oid, 'INSERT')
"""


def the_three_roles_exist(conn):
    rows = conn.execute(
        "SELECT rolname FROM pg_roles WHERE rolname = ANY(%s) ORDER BY rolname",
        (list(EXPECTED_ROLES),),
    ).fetchall()
    found = [r[0] for r in rows]
    if len(found) == len(EXPECTED_ROLES):
        return ("the three roles exist", "pass", ", ".join(found), "3 roles")
    missing = sorted(set(EXPECTED_ROLES) - set(found))
    return ("the three roles exist", "fail",
            f"{len(found)} of 3, missing {', '.join(missing)}; db/init.sql skipped every grant",
            "3 roles")


def dbt_cannot_read_conduct(conn):
    count = conn.execute(READABLE_SQL, ("fd", "dbt_owner")).fetchone()[0]
    return ("dbt cannot read conduct", "pass" if count == 0 else "fail",
            f"{count} fd table(s) readable by dbt_owner", "0")


def rails_cannot_read_the_archive(conn):
    count = conn.execute(READABLE_SQL, ("archive", "rails_app")).fetchone()[0]
    return ("rails cannot read the archive", "pass" if count == 0 else "fail",
            f"{count} archive table(s) readable by rails_app", "0")


def dbt_cannot_read_rails_state(conn):
    count = conn.execute(READABLE_SQL, ("app", "dbt_owner")).fetchone()[0]
    return ("dbt cannot read rails state", "pass" if count == 0 else "fail",
            f"{count} app table(s) readable by dbt_owner", "0")


def rails_cannot_write_analytics(conn):
    count = conn.execute(WRITABLE_SQL, ("analytics", "rails_app")).fetchone()[0]
    return ("rails cannot write analytics", "pass" if count == 0 else "fail",
            f"{count} analytics table(s) writable by rails_app", "0")


def the_pipeline_cannot_write_analytics(conn):
    count = conn.execute(WRITABLE_SQL, ("analytics", "pipeline_writer")).fetchone()[0]
    return ("the pipeline cannot write analytics", "pass" if count == 0 else "fail",
            f"{count} analytics table(s) writable by pipeline_writer", "0")


CHECKS = (
    the_three_roles_exist,
    dbt_cannot_read_conduct,
    rails_cannot_read_the_archive,
    dbt_cannot_read_rails_state,
    rails_cannot_write_analytics,
    the_pipeline_cannot_write_analytics,
)


def severity_of(status):
    return "info" if status == "pass" else "error"


def record(conn, run_id=None):
    results = [check(conn) for check in CHECKS]
    with conn.cursor() as cur:
        for assertion, status, observed, expected in results:
            cur.execute(RECORD_SQL, (run_id, assertion, severity_of(status), status, observed, expected))
    conn.commit()
    return results


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        results = record(conn)
    for assertion, status, observed, expected in results:
        print(f"{assertion:34} {status:4}  {observed}  (want {expected})")
    return 1 if any(status == "fail" for _, status, _, _ in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
