from dotenv import load_dotenv

from lib import audit_actions
from lib.db import connect
from lib.paths import ENV_FILE

SUBJECT = "audit_actions"
RECENT_DAYS = 7
SHOWN = 20

RECORD_SQL = """
INSERT INTO ingest.quality_result (run_id, subject, assertion, severity, status, observed, expected)
VALUES (%s, 'audit_actions', %s, %s, %s, %s, %s)
"""

RECENT_SQL = """
SELECT DISTINCT action FROM slack.audit_event
WHERE at > now() - make_interval(days => %s)
"""


def catalogued(conn):
    seen = [row[0] for row in conn.execute(RECENT_SQL, (RECENT_DAYS,)).fetchall()]
    missing = audit_actions.unknown(seen)
    if not missing:
        return ("every recent audit action has a catalogue entry", "pass",
                f"{len(seen)} action(s) in the last {RECENT_DAYS} days", "0 missing")
    listed = ", ".join(missing[:SHOWN]) + (f" and {len(missing) - SHOWN} more" if len(missing) > SHOWN else "")
    return ("every recent audit action has a catalogue entry", "warn",
            f"{len(missing)} missing from db/audit_actions.yml: {listed}", "0 missing")


CHECKS = (catalogued,)


def severity_of(status):
    return "warn" if status == "warn" else "info"


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
        print(f"{assertion:48} {status:4}  {observed}  (want {expected})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
