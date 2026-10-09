from lib import useragent
from lib.db import ingest_run

SOURCE = "useragent_reparse"
BATCH = 5000

UNREAD = """
SELECT id, ua
FROM slack.user_agent
WHERE read_at IS NULL
ORDER BY id DESC
LIMIT %s
"""

REREAD = """
UPDATE slack.user_agent
SET app = coalesce(%s, app),
    os = coalesce(%s, os),
    read_at = now()
WHERE id = %s
"""


def pass_over(conn, batch=BATCH):
    rows = conn.execute(UNREAD, (batch,)).fetchall()
    if not rows:
        return 0

    read = []
    for agent_id, ua in rows:
        seen = useragent.parse(ua)
        read.append((seen["ua_app"], seen["ua_os"], agent_id))

    with conn.cursor() as cur:
        cur.executemany(REREAD, read)
    conn.commit()
    return len(read)


def run(conn):
    with ingest_run(conn, SOURCE) as counts:
        counts.rows_in = pass_over(conn)

    print(f"{SOURCE}: {counts.rows_in} agent string(s) read again")
    return counts.rows_in
