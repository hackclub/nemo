import random

from lib.db import WORKER_BOOT, worker


class FencedOut(RuntimeError):
    pass


def backoff(attempt, base=1.0, cap=60.0, jitter=0.0):
    wait = min(cap, base * (2 ** max(0, attempt)))
    if jitter:
        wait += random.uniform(0, jitter)
    return wait


CLAIM_SQL = """
UPDATE {table}
SET    lease_until = now() + make_interval(secs => %(ttl)s),
       fence = fence + 1,
       worker = %(worker)s,
       worker_boot = %(boot)s::uuid,
       attempts = attempts + 1,
       updated_at = now()
WHERE  {where}
  AND  (lease_until IS NULL OR lease_until < now()
        OR (worker = %(worker)s AND worker_boot = %(boot)s::uuid))
RETURNING fence
"""

RENEW_SQL = """
UPDATE {table}
SET    lease_until = now() + make_interval(secs => %(ttl)s), updated_at = now()
WHERE  {where} AND fence = %(fence)s AND lease_until IS NOT NULL
RETURNING fence
"""

RELEASE_SQL = """
UPDATE {table}
SET    lease_until = NULL, updated_at = now()
WHERE  {where} AND fence = %(fence)s
RETURNING fence
"""


def _params(params, **more):
    merged = dict(params)
    merged.update(more, worker=worker(), boot=WORKER_BOOT)
    return merged


def claim(conn, table, where, params, ttl_seconds):
    with conn.cursor() as cur:
        cur.execute(CLAIM_SQL.format(table=table, where=where), _params(params, ttl=ttl_seconds))
        row = cur.fetchone()
    return row[0] if row else None


def renew(conn, table, where, params, fence, ttl_seconds):
    with conn.cursor() as cur:
        cur.execute(RENEW_SQL.format(table=table, where=where), _params(params, fence=fence, ttl=ttl_seconds))
        if cur.fetchone() is None:
            raise FencedOut(f"{table}: lease with fence {fence} is no longer ours")


def release(conn, table, where, params, fence):
    with conn.cursor() as cur:
        cur.execute(RELEASE_SQL.format(table=table, where=where), _params(params, fence=fence))
        return cur.fetchone() is not None
