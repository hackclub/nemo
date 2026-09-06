from lib import lease
from lib.db import connect

TABLE = "ingest.slice_coverage"
WHERE = "source_key = %(source_key)s AND slice_key = %(slice_key)s"
LEASE_SECONDS = 3600
SETTLED = ("complete", "unavailable")

INSERT_SQL = """
INSERT INTO ingest.slice_coverage (source_key, slice_key, slice_start, slice_end, state)
VALUES (%(source_key)s, %(slice_key)s, %(start)s, %(stop)s, 'claimed')
ON CONFLICT (source_key, slice_key) DO NOTHING
"""

MARK_CLAIMED_SQL = """
UPDATE ingest.slice_coverage
SET    state = 'claimed', run_id = %(run_id)s, claimed_at = now(), settled_at = NULL,
       slice_start = COALESCE(%(start)s, slice_start), slice_end = COALESCE(%(stop)s, slice_end)
WHERE  source_key = %(source_key)s AND slice_key = %(slice_key)s AND fence = %(fence)s
"""

SETTLE_SQL = """
UPDATE ingest.slice_coverage
SET    state = %(state)s, expected = %(expected)s, landed = %(landed)s, note = %(note)s,
       lease_until = NULL, settled_at = now(), updated_at = now()
WHERE  source_key = %(source_key)s AND slice_key = %(slice_key)s AND fence = %(fence)s
RETURNING id
"""

SUPERSEDE_SQL = """
UPDATE ingest.slice_coverage
SET    state = 'superseded', updated_at = now()
WHERE  source_key = %s AND slice_key <> %s AND state IN ('complete', 'short')
"""

ENUMERATE_SQL = """
SELECT slice_key, state, expected, landed
FROM   ingest.slice_coverage
WHERE  source_key = %s
"""


def claim_slice(conn, source_key, slice_key, start=None, stop=None, run_id=None, ttl_seconds=LEASE_SECONDS):
    params = {"source_key": source_key, "slice_key": slice_key, "start": start, "stop": stop}
    with conn.cursor() as cur:
        cur.execute(INSERT_SQL, params)
    fence = lease.claim(conn, TABLE, WHERE, params, ttl_seconds)
    if fence is None:
        conn.commit()
        return None
    with conn.cursor() as cur:
        cur.execute(MARK_CLAIMED_SQL, dict(params, run_id=run_id, fence=fence))
    conn.commit()
    return fence


def settle(conn, source_key, slice_key, fence, state, expected=None, landed=None, note=None):
    with conn.cursor() as cur:
        cur.execute(SETTLE_SQL, {
            "source_key": source_key, "slice_key": slice_key, "fence": fence, "state": state,
            "expected": expected, "landed": landed, "note": (note or None) and str(note)[:500],
        })
        if cur.fetchone() is None:
            raise lease.FencedOut(f"{source_key} {slice_key}: fence {fence} is no longer ours, verdict not written")


def settle_aside(source_key, slice_key, fence, state, expected=None, landed=None, note=None):
    try:
        with connect() as conn:
            settle(conn, source_key, slice_key, fence, state, expected, landed, note)
            conn.commit()
    except Exception as exc:
        print(f"{source_key} {slice_key}: could not write the {state} verdict, {type(exc).__name__}: {exc}")
        return False
    return True


def supersede(conn, source_key, keep_slice_key):
    with conn.cursor() as cur:
        cur.execute(SUPERSEDE_SQL, (source_key, keep_slice_key))
        return cur.rowcount


def enumerate_slices(conn, source_key):
    with conn.cursor() as cur:
        cur.execute(ENUMERATE_SQL, (source_key,))
        return {key: (state, expected, landed) for key, state, expected, landed in cur.fetchall()}


def covered(conn, source_key, states=SETTLED):
    return {key for key, (state, _, _) in enumerate_slices(conn, source_key).items() if state in states}
