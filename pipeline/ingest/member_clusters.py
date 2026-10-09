from datetime import timedelta

from ingest import member_links as links
from lib.db import ingest_run
from lib.graph import components

SOURCE = "member_clusters"
UNCLUSTERED_LABELS = ("household", "classroom")

EDGES_SQL = """
SELECT a_user_id, b_user_id
FROM fd.member_link_v2
WHERE score >= %(edge)s AND (label IS NULL OR NOT (label = ANY(%(unclustered)s)))
"""

ACCOUNTS_SQL = """
SELECT m.user_id, NOT m.is_deleted, j.joined_at
FROM fd.member m
LEFT JOIN fd.member_joins j ON j.user_id = m.user_id
WHERE m.user_id = ANY(%s)
"""

LAND = """
INSERT INTO fd.member_cluster (user_id, cluster_id, accounts, ring, active, computed_at)
VALUES (%s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    cluster_id = EXCLUDED.cluster_id,
    accounts = EXCLUDED.accounts,
    ring = EXCLUDED.ring,
    active = EXCLUDED.active,
    computed_at = EXCLUDED.computed_at
WHERE (fd.member_cluster.cluster_id, fd.member_cluster.accounts, fd.member_cluster.ring,
       fd.member_cluster.active)
      IS DISTINCT FROM (EXCLUDED.cluster_id, EXCLUDED.accounts, EXCLUDED.ring, EXCLUDED.active)
"""

SWEEP = "DELETE FROM fd.member_cluster WHERE NOT (user_id = ANY(%s))"


def settings(held=None):
    return (held or links.catalogue())["clusters"]


def burst(times, window):
    held = sorted(one for one in times if one is not None)
    most = 0
    start = 0
    for end, at in enumerate(held):
        while at - held[start] > window:
            start += 1
        most = max(most, end - start + 1)
    return most


def oldest(group, joined):
    return min(group, key=lambda one: (joined.get(one) is None, joined.get(one) or 0, one))


def cluster_rows(groups, accounts, rule):
    joined = {user_id: at for user_id, (_active, at) in accounts.items()}
    window = timedelta(minutes=rule["window_minutes"])
    rows = []
    for group in groups:
        cluster_id = oldest(group, joined)
        ring = (len(group) >= rule["min_accounts"]
                and burst([joined.get(one) for one in group], window) >= rule["min_accounts"])
        for user_id in sorted(group):
            active = accounts.get(user_id, (True, None))[0]
            rows.append((user_id, cluster_id, len(group), ring, active))
    return rows


def run(conn):
    held = settings()
    with ingest_run(conn, SOURCE) as counts:
        edges = conn.execute(EDGES_SQL, {"edge": held["edge_score"],
                                         "unclustered": list(UNCLUSTERED_LABELS)}).fetchall()
        groups = components((a, b) for a, b in edges)
        members = sorted(set().union(*groups)) if groups else []
        accounts = {row[0]: (row[1], row[2])
                    for row in conn.execute(ACCOUNTS_SQL, (members,)).fetchall()} if members else {}
        rows = cluster_rows(groups, accounts, held["ring"])
        with conn.cursor() as cur:
            if rows:
                cur.executemany(LAND, rows)
            cur.execute(SWEEP, (members,))
            gone = cur.rowcount
        conn.commit()
        counts.rows_in = len(rows)

    rings = len({row[1] for row in rows if row[3]})
    print(f"{SOURCE}: {len(groups)} cluster(s) over {len(rows)} account(s), {rings} ring(s), "
          f"{gone} account(s) no longer clustered")
    return len(rows)
