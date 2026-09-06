import sys

from dotenv import load_dotenv

from ingest import first_reply, member_history
from lib.db import connect
from lib.paths import ENV_FILE

RECORD_SQL = """
INSERT INTO ingest.quality_result (run_id, subject, assertion, severity, status, observed, expected)
VALUES (%s, 'work_queue', %s, %s, %s, %s, %s)
"""

UNQUEUED_HISTORY_SQL = f"""
SELECT count(*) FROM ({member_history.PENDING_BODY}) p
LEFT JOIN ingest.work_item w
       ON w.work_kind = 'member_history' AND w.target_key = p.user_id AND w.state IN ('pending', 'claimed')
WHERE w.work_item_id IS NULL
"""

UNQUEUED_REPLY_SQL = f"""
SELECT count(*) FROM ({first_reply.PENDING_BODY}) p
LEFT JOIN ingest.work_item w
       ON w.work_kind = 'first_reply' AND w.target_key = p.user_id AND w.state IN ('pending', 'claimed')
WHERE w.work_item_id IS NULL
"""

UNQUEUED_THREADS_SQL = """
SELECT count(*)
FROM raw.thread t
JOIN app.channel_backfill b ON b.channel_id = t.channel_id AND b.state IN ('queued', 'draining')
LEFT JOIN ingest.work_item w
       ON w.work_kind = 'channel_replies' AND w.target_key = t.channel_id
      AND w.target_sub_key = t.root_ts AND w.state IN ('pending', 'claimed')
WHERE t.replies_fetched < t.reply_count AND w.work_item_id IS NULL
"""

STALE_LEASES_SQL = """
SELECT count(*) FROM ingest.work_item
WHERE state = 'claimed' AND lease_until < now() - interval '15 minutes'
"""

DEAD_SQL = "SELECT count(*) FROM ingest.work_item WHERE state = 'dead'"

DUPLICATE_HISTORY_SQL = """
SELECT count(*) FROM (
    SELECT target_key FROM ingest.work_item
    WHERE work_kind = 'member_history' GROUP BY target_key HAVING count(*) > 1
) d
"""


def one(conn, sql, params=()):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()[0]


def r1_every_unsearched_member_is_queued(conn):
    return "R1", one(conn, UNQUEUED_HISTORY_SQL, (member_history.MEMBER_RANGE_SOURCE,)), 0


def r2_every_unchecked_first_post_is_queued(conn):
    return "R2", one(conn, UNQUEUED_REPLY_SQL, (first_reply.WALK_VERSION,)), 0


def r3_every_pending_thread_of_a_draining_channel_is_queued(conn):
    return "R3", one(conn, UNQUEUED_THREADS_SQL), 0


def r4_no_lease_outlives_its_expiry(conn):
    return "R4", one(conn, STALE_LEASES_SQL), 0


def r5_one_unit_per_member(conn):
    return "R5", one(conn, DUPLICATE_HISTORY_SQL), 0


def r6_dead_units(conn):
    return "R6", one(conn, DEAD_SQL), 0


CHECKS = (
    r1_every_unsearched_member_is_queued,
    r2_every_unchecked_first_post_is_queued,
    r3_every_pending_thread_of_a_draining_channel_is_queued,
    r4_no_lease_outlives_its_expiry,
    r5_one_unit_per_member,
    r6_dead_units,
)

SEVERITY = {"R6": "warn"}


def verdicts(conn):
    results = []
    for check in CHECKS:
        assertion, observed, expected = check(conn)
        status = "pass" if observed == expected else "fail"
        results.append((assertion, status, observed, expected))
    return results


def record(conn, run_id=None):
    results = verdicts(conn)
    with conn.cursor() as cur:
        for assertion, status, observed, expected in results:
            severity = SEVERITY.get(assertion, "error") if status == "fail" else "info"
            cur.execute(RECORD_SQL, (run_id, assertion, severity, status, observed, expected))
    conn.commit()
    return results


def main():
    load_dotenv(ENV_FILE)
    with connect() as conn:
        results = record(conn)
    for assertion, status, observed, expected in results:
        print(f"{assertion:3} {status:4}  {observed}  (want {expected})")
    return 1 if any(status == "fail" and SEVERITY.get(a) != "warn" for a, status, _, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
