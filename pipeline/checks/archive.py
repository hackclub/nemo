from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE

FRESH_HOURS = 6
SUBJECT = "archive"

RECORD_SQL = """
INSERT INTO ingest.quality_result (run_id, subject, assertion, severity, status, observed, expected)
VALUES (%s, 'archive', %s, %s, %s, %s, %s)
"""

WARN_ONLY = frozenset({
    "unconfirmed rows",
    "channels Slack will not return",
    "threads still to fetch",
    "share of Slack's day held",
})


def hours_since_the_last_write(conn):
    row = conn.execute("SELECT max(updated_at), now() - max(updated_at) FROM archive.message").fetchone()
    if row is None or row[0] is None:
        return ("last write", "fail", "the archive holds nothing", f"under {FRESH_HOURS}h")
    hours = row[1].total_seconds() / 3600
    return ("last write", "pass" if hours < FRESH_HOURS else "fail",
            f"{hours:.1f}h ago", f"under {FRESH_HOURS}h")


def unconfirmed_rows(conn):
    count = conn.execute("SELECT count(*) FROM archive.message WHERE revision = 0").fetchone()[0]
    return ("unconfirmed rows", "pass" if count == 0 else "warn",
            f"{count} row(s) seeded and never fetched", "0")


def events_waiting_to_be_projected(conn):
    count = conn.execute(
        "SELECT count(*) FROM raw.event_delivery WHERE projected_at IS NULL"
    ).fetchone()[0]
    return ("events to project", "pass" if count == 0 else "fail", f"{count} waiting", "0")


def channels_still_to_walk(conn):
    count = conn.execute("""
        SELECT count(*)
        FROM raw.channel_dim d
        LEFT JOIN raw.channel_walk w ON w.channel_id = d.channel_id
        WHERE coalesce(w.history_complete, false) = false
          AND coalesce(w.last_error, '') NOT LIKE 'entity:%'
    """).fetchone()[0]
    return ("channels to walk", "pass" if count == 0 else "fail", f"{count} reachable channel(s)", "0")


def channels_slack_will_not_return(conn):
    count = conn.execute(
        "SELECT count(*) FROM raw.channel_walk WHERE last_error LIKE 'entity:%'"
    ).fetchone()[0]
    return ("channels Slack will not return", "pass" if count == 0 else "warn",
            f"{count} channel(s) permanently out of reach", "0")


def threads_still_to_fetch(conn):
    owed, known = conn.execute(
        "SELECT count(*) FILTER (WHERE fetched_at IS NULL), count(*) FROM raw.thread"
    ).fetchone()
    return ("threads still to fetch", "pass" if owed == 0 else "warn",
            f"{owed} of {known} thread(s)", "0")


def share_of_slacks_day_held(conn):
    row = conn.execute("""
        WITH day AS (
            SELECT max(window_start) AS ds
            FROM raw.channel_activity_snapshot
            WHERE source = 'admin_analytics_api' AND window_start = window_end
        ),
        slack AS (
            SELECT coalesce(sum(s.messages_posted), 0) AS said
            FROM raw.channel_activity_snapshot s CROSS JOIN day d
            WHERE s.source = 'admin_analytics_api' AND s.window_start = d.ds AND s.window_end = d.ds
        ),
        held AS (
            SELECT count(*) AS got
            FROM archive.message m CROSS JOIN day d
            WHERE m.deleted_at IS NULL
              AND (m.posted_at AT TIME ZONE 'UTC')::date = d.ds
        )
        SELECT d.ds, slack.said, held.got FROM day d CROSS JOIN slack CROSS JOIN held
    """).fetchone()
    ds, said, got = row
    if not said:
        return ("share of Slack's day held", "pass", "Slack reported no messages", "n/a")
    share = 100.0 * got / said
    return ("share of Slack's day held", "pass" if share >= 95 else "warn",
            f"{share:.1f}% of {said} on {ds}", "95% or more")


CHECKS = (
    hours_since_the_last_write,
    unconfirmed_rows,
    events_waiting_to_be_projected,
    channels_still_to_walk,
    channels_slack_will_not_return,
    threads_still_to_fetch,
    share_of_slacks_day_held,
)


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
        print(f"{assertion:32} {status:4}  {observed}  (want {expected})")
    return 1 if any(status == "fail" for _, status, _, _ in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
