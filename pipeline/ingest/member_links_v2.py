from ingest import member_links as links
from lib.db import ingest_run

SOURCE = "member_links_v2"

PASS = """
CREATE TEMP TABLE link_pass ON COMMIT DROP AS
WITH family_of AS (
    SELECT * FROM unnest(%(signals)s::text[], %(families)s::text[], %(caps)s::numeric[],
                         %(corroborating)s::boolean[])
        AS f(signal, family, cap, corroborating)
),
best AS (
    SELECT DISTINCT ON (a_user_id, b_user_id, signal)
           a_user_id, b_user_id, signal, value, people, score, first_seen, last_seen
    FROM link_part
    ORDER BY a_user_id, b_user_id, signal, score DESC
),
family AS (
    SELECT b.a_user_id, b.b_user_id, f.family,
           least(sum(b.score), f.cap) AS score,
           bool_and(f.corroborating) AS corroborating,
           min(b.first_seen) AS first_seen,
           max(b.last_seen) AS last_seen
    FROM best b
    JOIN family_of f ON f.signal = b.signal
    GROUP BY b.a_user_id, b.b_user_id, f.family, f.cap
),
pair AS (
    SELECT a_user_id, b_user_id,
           round(sum(score)::numeric, 3) AS score,
           (array_agg(family ORDER BY score DESC))[1] AS top_family,
           jsonb_object_agg(family, round(score::numeric, 3)) AS families,
           min(first_seen) AS first_seen,
           max(last_seen) AS last_seen
    FROM family
    GROUP BY a_user_id, b_user_id
    HAVING sum(score) >= %(floor)s AND bool_or(NOT corroborating)
)
SELECT p.a_user_id, p.b_user_id, p.score, p.top_family, p.families,
       (SELECT jsonb_object_agg(b.signal, jsonb_build_object(
                   'value', b.value, 'people', b.people, 'score', round(b.score::numeric, 3)))
        FROM best b
        WHERE b.a_user_id = p.a_user_id AND b.b_user_id = p.b_user_id) AS signals,
       p.first_seen, p.last_seen
FROM pair p
"""

PASS_INDEX = "CREATE INDEX ON link_pass (a_user_id, b_user_id)"

LAND = """
INSERT INTO fd.member_link_v2
    (a_user_id, b_user_id, score, top_family, families, signals, first_seen, last_seen, computed_at)
SELECT a_user_id, b_user_id, score, top_family, families, signals, first_seen, last_seen, now()
FROM link_pass
ON CONFLICT (a_user_id, b_user_id) DO UPDATE SET
    score = EXCLUDED.score,
    top_family = EXCLUDED.top_family,
    families = EXCLUDED.families,
    signals = EXCLUDED.signals,
    first_seen = EXCLUDED.first_seen,
    last_seen = EXCLUDED.last_seen,
    computed_at = EXCLUDED.computed_at
WHERE (fd.member_link_v2.score, fd.member_link_v2.top_family, fd.member_link_v2.families,
       fd.member_link_v2.signals, fd.member_link_v2.first_seen, fd.member_link_v2.last_seen)
      IS DISTINCT FROM (EXCLUDED.score, EXCLUDED.top_family, EXCLUDED.families,
                        EXCLUDED.signals, EXCLUDED.first_seen, EXCLUDED.last_seen)
"""

SWEEP = """
DELETE FROM fd.member_link_v2 l
WHERE NOT EXISTS (SELECT 1 FROM link_pass p
                  WHERE p.a_user_id = l.a_user_id AND p.b_user_id = l.b_user_id)
"""


def families(held=None):
    return (held or links.catalogue())["families"]


def family_table(held):
    caps = families(held)
    rows = [(name, one["family"], caps[one["family"]]["cap"], bool(one.get("corroborating")))
            for name, one in links.signals(held).items()]
    return {"signals": [row[0] for row in rows], "families": [row[1] for row in rows],
            "caps": [row[2] for row in rows], "corroborating": [row[3] for row in rows]}


def run(conn):
    held = links.catalogue()
    marks = links.scoring(held)

    with ingest_run(conn, SOURCE) as counts:
        put_aside = links.mark_shared(conn, held)
        found = links.gather(conn, held)
        with conn.cursor() as cur:
            cur.execute(PASS, {**family_table(held), "floor": marks["floor"]})
            cur.execute(PASS_INDEX)
            cur.execute(LAND)
            changed = cur.rowcount
            cur.execute(SWEEP)
            gone = cur.rowcount
            cur.execute("SELECT count(*) FROM link_pass")
            kept = cur.fetchone()[0]
        conn.commit()
        counts.rows_in = changed

    per_signal = ", ".join(f"{name} {n}" for name, n in sorted(found.items()) if n)
    print(f"{SOURCE}: {kept} link(s) kept, {changed} written, {gone} dropped, "
          f"{put_aside} address(es) on shared networks left out ({per_signal})")
    return changed
