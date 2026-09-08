from collections import namedtuple

from lib import lease
from lib.db import WORKER_BOOT, worker

TABLE = "ingest.work_item"
WHERE_ID = "work_item_id = %(id)s"
LEASE_SECONDS = 600
MAX_ATTEMPTS = 5
MAX_LAPSES = 10
OPEN = ("pending", "claimed")
SETTLED = ("complete", "short", "unavailable")

Item = namedtuple("Item", "id target_key sub_key payload expected attempts fence")

ENQUEUE_SQL = """
INSERT INTO ingest.work_item
    (work_kind, target_key, target_sub_key, priority, payload, expected, requested_by)
SELECT %(kind)s, q.target_key, coalesce(q.target_sub_key, ''), coalesce(q.priority, 100),
       coalesce(q.payload, '{{}}'::jsonb), q.expected, %(requested_by)s
FROM ({select}) q
ON CONFLICT (work_kind, target_key, target_sub_key) {conflict}
"""

CONFLICT_IGNORE = "DO NOTHING"
CONFLICT_GROWN = """DO UPDATE SET
    expected = EXCLUDED.expected, state = 'pending', next_attempt_at = NULL, updated_at = now()
WHERE ingest.work_item.state <> 'claimed'
  AND EXCLUDED.expected > coalesce(ingest.work_item.fetched, 0)
  AND ingest.work_item.state <> 'pending'"""

CONFLICT_SETTLED_AGO = """DO UPDATE SET
    state = 'pending', next_attempt_at = NULL, priority = EXCLUDED.priority, updated_at = now()
WHERE ingest.work_item.state IN ('complete', 'short', 'unavailable')
  AND ingest.work_item.settled_at < now() - make_interval(secs => %(requeue_after)s)"""

CLAIM_SQL = """
WITH picked AS (
    SELECT work_item_id
    FROM   ingest.work_item
    WHERE  work_kind = %(kind)s AND state = 'pending'
      AND  (next_attempt_at IS NULL OR next_attempt_at <= now())
      AND  (%(targets)s::text[] IS NULL OR target_key = ANY(%(targets)s::text[]))
    ORDER BY priority, created_at
    LIMIT  %(limit)s
    FOR UPDATE SKIP LOCKED
)
UPDATE ingest.work_item w
SET    state = 'claimed', worker = %(worker)s, worker_boot = %(boot)s::uuid,
       lease_until = now() + make_interval(secs => %(ttl)s), fence = w.fence + 1,
       attempts = w.attempts + 1, claimed_by = %(worker)s, claimed_at = now(), updated_at = now()
FROM   picked
WHERE  w.work_item_id = picked.work_item_id
RETURNING w.work_item_id, w.target_key, w.target_sub_key, w.payload, w.expected, w.attempts, w.fence
"""

SETTLE_SQL = """
UPDATE ingest.work_item
SET    state = %(state)s, fetched = %(fetched)s, note = %(note)s, lease_until = NULL,
       settled_at = now(), updated_at = now()
WHERE  work_item_id = %(id)s AND fence = %(fence)s AND state = 'claimed'
"""

FAIL_SQL = """
UPDATE ingest.work_item
SET    state = CASE WHEN attempts >= %(max_attempts)s THEN 'dead' ELSE 'pending' END,
       next_attempt_at = now() + make_interval(secs => %(wait)s),
       last_error = %(note)s, lease_until = NULL, updated_at = now()
WHERE  work_item_id = %(id)s AND fence = %(fence)s AND state = 'claimed'
RETURNING state
"""

RELEASE_SQL = """
UPDATE ingest.work_item
SET    state = 'pending', attempts = greatest(attempts - 1, 0), lease_until = NULL, updated_at = now()
WHERE  work_item_id = %(id)s AND fence = %(fence)s AND state = 'claimed'
"""

RELEASE_MINE_SQL = """
UPDATE ingest.work_item
SET    state = 'pending', attempts = greatest(attempts - 1, 0), lease_until = NULL,
       next_attempt_at = now(), updated_at = now()
WHERE  state = 'claimed' AND worker = %(worker)s AND worker_boot = %(boot)s::uuid
  AND  (%(kind)s::text IS NULL OR work_kind = %(kind)s)
RETURNING work_kind
"""

RECLAIM_SQL = """
UPDATE ingest.work_item
SET    state = CASE WHEN lapses + 1 >= %(max_lapses)s THEN 'dead' ELSE 'pending' END,
       attempts = greatest(attempts - 1, 0),
       lapses = lapses + 1,
       lease_until = NULL, next_attempt_at = now(),
       last_error = coalesce(last_error, 'lease expired'), updated_at = now()
WHERE  state = 'claimed' AND lease_until < now()
  AND  (%(kind)s::text IS NULL OR work_kind = %(kind)s)
RETURNING work_kind, state
"""

DEPTH_SQL = """
SELECT state, count(*) FROM ingest.work_item WHERE work_kind = %s GROUP BY state
"""


def enqueue_select(conn, kind, select_sql, params=(), requested_by=None, requeue_when_grown=False,
                   requeue_settled_after=None):
    conflict = CONFLICT_IGNORE
    if requeue_when_grown:
        conflict = CONFLICT_GROWN
    elif requeue_settled_after is not None:
        conflict = CONFLICT_SETTLED_AGO
    sql = ENQUEUE_SQL.format(select=select_sql, conflict=conflict)
    with conn.cursor() as cur:
        cur.execute(sql, {"kind": kind, "requested_by": requested_by, "requeue_after": requeue_settled_after,
                          **_positional(params)})
        queued = cur.rowcount
    conn.commit()
    return queued


def _positional(params):
    return {f"p{i}": value for i, value in enumerate(params)}


def claim(conn, kind, limit=1, ttl_seconds=LEASE_SECONDS, targets=None):
    with conn.cursor() as cur:
        cur.execute(CLAIM_SQL, {"kind": kind, "limit": limit, "ttl": ttl_seconds, "worker": worker(),
                               "boot": WORKER_BOOT, "targets": list(targets) if targets else None})
        items = [Item(*row) for row in cur.fetchall()]
    conn.commit()
    return items


def renew(conn, item, ttl_seconds=LEASE_SECONDS):
    lease.renew(conn, TABLE, WHERE_ID, {"id": item.id}, item.fence, ttl_seconds)


def settle(conn, item, state, fetched=None, note=None):
    with conn.cursor() as cur:
        cur.execute(SETTLE_SQL, {"id": item.id, "fence": item.fence, "state": state,
                                 "fetched": fetched, "note": note and str(note)[:500]})
        if cur.rowcount == 0:
            raise lease.FencedOut(f"work item {item.id}: fence {item.fence} is no longer ours")


def settle_many(conn, outcomes):
    if not outcomes:
        return 0
    with conn.cursor() as cur:
        cur.executemany(SETTLE_SQL, [
            {"id": item.id, "fence": item.fence, "state": state, "fetched": fetched, "note": None}
            for item, state, fetched in outcomes
        ])
    return len(outcomes)


def fail(conn, item, note, max_attempts=MAX_ATTEMPTS):
    with conn.cursor() as cur:
        cur.execute(FAIL_SQL, {"id": item.id, "fence": item.fence, "note": str(note)[:500],
                               "wait": lease.backoff(item.attempts, base=30.0, cap=6 * 3600),
                               "max_attempts": max_attempts})
        row = cur.fetchone()
    return row[0] if row else None


def release(conn, item):
    with conn.cursor() as cur:
        cur.execute(RELEASE_SQL, {"id": item.id, "fence": item.fence})
    conn.commit()


def release_mine(conn, kind=None):
    with conn.cursor() as cur:
        cur.execute(RELEASE_MINE_SQL, {"kind": kind, "worker": worker(), "boot": WORKER_BOOT})
        rows = cur.fetchall()
    conn.commit()
    if rows:
        print(f"work: handed back {len(rows)} claimed unit(s) on the way out")
    return len(rows)


def reclaim(conn, kind=None, max_lapses=MAX_LAPSES):
    with conn.cursor() as cur:
        cur.execute(RECLAIM_SQL, {"kind": kind, "max_lapses": max_lapses})
        rows = cur.fetchall()
    conn.commit()
    if rows:
        dead = sum(1 for _, state in rows if state == "dead")
        print(f"work: reclaimed {len(rows)} expired lease(s)" + (f", {dead} now dead" if dead else ""))
    return len(rows)


PRIORITIZE_SQL = """
UPDATE ingest.work_item
SET    priority = least(priority, %(priority)s), updated_at = now()
WHERE  work_kind = %(kind)s AND target_key = ANY(%(keys)s) AND state = 'pending'
"""


def prioritize(conn, kind, keys, priority):
    with conn.cursor() as cur:
        cur.execute(PRIORITIZE_SQL, {"kind": kind, "keys": list(keys), "priority": priority})
        moved = cur.rowcount
    conn.commit()
    return moved


def depth(conn, kind):
    with conn.cursor() as cur:
        cur.execute(DEPTH_SQL, (kind,))
        return dict(cur.fetchall())


def outcome_after_failure(attempts, max_attempts=MAX_ATTEMPTS):
    return "dead" if attempts >= max_attempts else "pending"


def outcome_after_lapse(lapses, max_lapses=MAX_LAPSES):
    return "dead" if lapses + 1 >= max_lapses else "pending"
