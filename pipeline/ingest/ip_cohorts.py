from lib.db import ingest_run

SOURCE = "ip_cohorts"

REFRESH_SQL = """
INSERT INTO fd.ip_cohort (ip_prefix, people, logins, first_seen, last_seen, refreshed_at)
SELECT ip_prefix,
       count(DISTINCT user_id),
       sum(hits),
       min(first_at),
       max(last_at),
       now()
FROM fd.login_event
WHERE ip_prefix IS NOT NULL
GROUP BY ip_prefix
ON CONFLICT (ip_prefix) DO UPDATE SET
    people = EXCLUDED.people,
    logins = EXCLUDED.logins,
    first_seen = least(EXCLUDED.first_seen, fd.ip_cohort.first_seen),
    last_seen = greatest(EXCLUDED.last_seen, fd.ip_cohort.last_seen),
    refreshed_at = now()
WHERE (fd.ip_cohort.people, fd.ip_cohort.logins, fd.ip_cohort.first_seen, fd.ip_cohort.last_seen)
      IS DISTINCT FROM (EXCLUDED.people, EXCLUDED.logins,
                        least(EXCLUDED.first_seen, fd.ip_cohort.first_seen),
                        greatest(EXCLUDED.last_seen, fd.ip_cohort.last_seen))
"""

STALE_SQL = """
SELECT count(*) FROM fd.ip_cohort WHERE refreshed_at < now() - interval '1 hour'
"""


def run(conn):
    with ingest_run(conn, SOURCE) as counts:
        with conn.cursor() as cur:
            cur.execute(REFRESH_SQL)
            counts.rows_in = cur.rowcount
        conn.commit()

    print(f"{SOURCE}: {counts.rows_in} prefix(es)")
    return counts.rows_in
