from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE

SUBJECT = "parity"
TOLERANCE = 0.001

RECORD_SQL = """
INSERT INTO ingest.quality_result (run_id, subject, assertion, severity, status, observed, expected)
VALUES (%s, 'parity', %s, %s, %s, %s, %s)
"""


def verdict(assertion, legacy, archived, tolerance=TOLERANCE):
    if legacy == 0 and archived == 0:
        return (assertion, "pass", "both stores hold nothing", "equal")
    drift = abs(legacy - archived) / max(legacy, archived)
    status = "pass" if drift <= tolerance else "fail"
    return (assertion, status,
            f"legacy {legacy}, archive {archived}, {drift * 100:.3f}% apart",
            f"within {tolerance * 100:g}%")


def rows_in_each_store(conn):
    legacy = conn.execute("SELECT count(*) FROM raw.message").fetchone()[0]
    archived = conn.execute("SELECT count(*) FROM archive.message").fetchone()[0]
    return verdict("message rows", legacy, archived)


def rows_the_archive_is_missing(conn):
    count = conn.execute("""
        SELECT count(*) FROM raw.message r
        LEFT JOIN archive.message a ON a.channel_id = r.channel_id AND a.ts = r.ts
        WHERE a.ts IS NULL
    """).fetchone()[0]
    return ("rows only in the legacy spine", "pass" if count == 0 else "fail",
            f"{count} row(s) the archive never saw", "0")


def rows_only_the_archive_holds(conn):
    count = conn.execute("""
        SELECT count(*) FROM archive.message a
        LEFT JOIN raw.message r ON r.channel_id = a.channel_id AND r.ts = a.ts
        WHERE r.ts IS NULL
    """).fetchone()[0]
    return ("rows only in the archive", "pass" if count == 0 else "warn",
            f"{count} row(s) the legacy spine never saw", "0")


def authors_agree(conn):
    count = conn.execute("""
        SELECT count(*) FROM archive.message a
        JOIN raw.message r ON r.channel_id = a.channel_id AND r.ts = a.ts
        WHERE a.author_id IS DISTINCT FROM r.author_id
    """).fetchone()[0]
    return ("authors agree", "pass" if count == 0 else "fail",
            f"{count} row(s) name a different author", "0")


def the_projection_keeps_up_with_the_log(conn):
    count = conn.execute("""
        SELECT count(*) FROM archive.message m
        JOIN (SELECT channel_id, ts, max(revision) AS top FROM archive.envelope
              GROUP BY channel_id, ts) e
          ON e.channel_id = m.channel_id AND e.ts = m.ts
        WHERE m.revision < e.top
    """).fetchone()[0]
    return ("the projection matches the log", "pass" if count == 0 else "warn",
            f"{count} row(s) behind their newest envelope", "0")


CHECKS = (
    rows_in_each_store,
    rows_the_archive_is_missing,
    rows_only_the_archive_holds,
    authors_agree,
    the_projection_keeps_up_with_the_log,
)

WARN_ONLY = frozenset({"rows only in the archive", "the projection matches the log"})


def severity_of(assertion, status):
    if status == "pass":
        return "info"
    return "warn" if assertion in WARN_ONLY else "error"


def record(conn, run_id=None):
    results = [check(conn) for check in CHECKS]
    with conn.cursor() as cur:
        for assertion, status, observed, expected in results:
            cur.execute(RECORD_SQL,
                        (run_id, assertion, severity_of(assertion, status), status, observed, expected))
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
