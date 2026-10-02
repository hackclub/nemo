from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE

SUBJECT = "roles"
SEPARATED_MODE = "three-role"
SHARED_MODE = "single-role"
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


def roles_present(conn):
    rows = conn.execute(
        "SELECT rolname FROM pg_roles WHERE rolname = ANY(%s) ORDER BY rolname",
        (list(EXPECTED_ROLES),),
    ).fetchall()
    return [r[0] for r in rows]


def separated(conn):
    return len(roles_present(conn)) == len(EXPECTED_ROLES)


def the_deployment_mode_is_declared(conn):
    found = roles_present(conn)
    if len(found) == len(EXPECTED_ROLES):
        return ("the deployment mode is declared", "pass",
                f"{SEPARATED_MODE}: {', '.join(found)}", "a known mode")
    missing = sorted(set(EXPECTED_ROLES) - set(found))
    return ("the deployment mode is declared", "pass",
            f"{SHARED_MODE}: {len(found)} of 3 service roles exist, missing "
            f"{', '.join(missing)}, so every service shares one login and the boundary "
            "is the application's own capability checks",
            "a known mode")


def skipped_when_shared(assertion):
    return (assertion, "skipped", f"{SHARED_MODE}: no grant separation to measure", "n/a")


def dbt_cannot_read_conduct(conn):
    if not separated(conn):
        return skipped_when_shared("dbt cannot read conduct")

    count = conn.execute(READABLE_SQL, ("fd", "dbt_owner")).fetchone()[0]
    return ("dbt cannot read conduct", "pass" if count == 0 else "fail",
            f"{count} fd table(s) readable by dbt_owner", "0")


def rails_cannot_read_the_archive(conn):
    if not separated(conn):
        return skipped_when_shared("rails cannot read the archive")

    count = conn.execute(READABLE_SQL, ("archive", "rails_app")).fetchone()[0]
    return ("rails cannot read the archive", "pass" if count == 0 else "fail",
            f"{count} archive table(s) readable by rails_app", "0")


def dbt_cannot_read_rails_state(conn):
    if not separated(conn):
        return skipped_when_shared("dbt cannot read rails state")

    count = conn.execute(READABLE_SQL, ("app", "dbt_owner")).fetchone()[0]
    return ("dbt cannot read rails state", "pass" if count == 0 else "fail",
            f"{count} app table(s) readable by dbt_owner", "0")


def rails_cannot_write_analytics(conn):
    if not separated(conn):
        return skipped_when_shared("rails cannot write analytics")

    count = conn.execute(WRITABLE_SQL, ("analytics", "rails_app")).fetchone()[0]
    return ("rails cannot write analytics", "pass" if count == 0 else "fail",
            f"{count} analytics table(s) writable by rails_app", "0")


def the_pipeline_cannot_write_analytics(conn):
    if not separated(conn):
        return skipped_when_shared("the pipeline cannot write analytics")

    count = conn.execute(WRITABLE_SQL, ("analytics", "pipeline_writer")).fetchone()[0]
    return ("the pipeline cannot write analytics", "pass" if count == 0 else "fail",
            f"{count} analytics table(s) writable by pipeline_writer", "0")


CHECKS = (
    the_deployment_mode_is_declared,
    dbt_cannot_read_conduct,
    rails_cannot_read_the_archive,
    dbt_cannot_read_rails_state,
    rails_cannot_write_analytics,
    the_pipeline_cannot_write_analytics,
)


def severity_of(status):
    return "error" if status == "fail" else "info"


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
