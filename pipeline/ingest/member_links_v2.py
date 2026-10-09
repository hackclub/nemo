from ingest import member_links as links
from lib.db import ingest_run

SOURCE = "member_links_v2"
NETWORK = "network"
DEVICE = "device"
DEVICE_AGENT = "device_agent"
DEVICE_JA4 = "device_ja4"
SHORTEST_AGENT = 20
IP_STABLE = "ip_stable"
IP_SAME_HOUR = "ip_same_hour"
IP_MANY = "ip_many"
IP_HOURLY = "ip_hourly"
IP_PREFIX_STABLE = "ip_prefix_stable"
COLLAPSED = (IP_SAME_HOUR, IP_HOURLY)
TWO_COUNTRIES = "two_countries"

SIGHTING = """
CREATE TEMP TABLE sighting ON COMMIT DROP AS
SELECT e.user_id, e.ip, e.ip_prefix, date_trunc('hour', e.at) AS hour, count(*) AS seen,
       CASE WHEN n.class IN ('rotating', 'vpn', 'hosting', 'tor') THEN n.class
            WHEN EXISTS (SELECT 1 FROM shared_ip s WHERE s.ip = e.ip) THEN 'rotating'
            ELSE 'stable' END AS class
FROM fd.login_event e
LEFT JOIN fd.ip_network n ON n.ip_prefix = e.ip_prefix
WHERE e.ip IS NOT NULL
GROUP BY e.user_id, e.ip, e.ip_prefix, date_trunc('hour', e.at), n.class
"""

NETWORK_EVIDENCE = {
    IP_STABLE: """
        SELECT user_id, host(ip) AS value, min(hour) AS first_seen, max(hour) AS last_seen
        FROM sighting
        WHERE class = 'stable'
        GROUP BY 1, 2
        HAVING sum(seen) >= {sightings}
    """,
    IP_SAME_HOUR: """
        SELECT user_id, host(ip) || ' ' || to_char(hour, 'YYYY-MM-DD HH24') AS value,
               hour AS first_seen, hour AS last_seen
        FROM sighting
        WHERE class = 'stable'
    """,
    IP_PREFIX_STABLE: """
        SELECT user_id, host(ip_prefix) AS value, min(hour) AS first_seen, max(hour) AS last_seen
        FROM sighting
        WHERE class = 'stable' AND ip_prefix IS NOT NULL
        GROUP BY 1, 2
        HAVING sum(seen) >= {sightings}
    """,
    IP_HOURLY: """
        SELECT e.user_id,
               host(e.ip) || ' ' || to_char(date_trunc('hour', e.at), 'YYYY-MM-DD HH24')
                   || ' ' || left(md5(e.ua), 12) AS value,
               min(e.at) AS first_seen, max(e.at) AS last_seen
        FROM fd.login_event e
        LEFT JOIN fd.ip_network n ON n.ip_prefix = e.ip_prefix
        WHERE e.ip IS NOT NULL AND e.ua IS NOT NULL
          AND (n.class IN ('rotating', 'vpn', 'hosting', 'tor')
               OR EXISTS (SELECT 1 FROM shared_ip s WHERE s.ip = e.ip))
        GROUP BY 1, 2
    """,
}

DEVICE_EVIDENCE = {
    DEVICE_AGENT: """
        SELECT user_id, ua AS value, min(at) AS first_seen, max(at) AS last_seen
        FROM fd.login_event
        WHERE ua IS NOT NULL AND length(ua) >= {shortest}
        GROUP BY 1, 2
    """,
    DEVICE_JA4: """
        SELECT actor_id AS user_id, payload->'details'->>'client_ja4_fingerprint' AS value,
               min(at) AS first_seen, max(at) AS last_seen
        FROM slack.audit_event
        WHERE action = 'anomaly' AND actor_id IS NOT NULL
          AND payload->'details'->>'client_ja4_fingerprint' IS NOT NULL
        GROUP BY 1, 2
    """,
}

PART = """
INSERT INTO link_part (a_user_id, b_user_id, signal, value, people, score, first_seen, last_seen)
SELECT a_user_id, b_user_id, %(name)s, value, people, score, first_seen, last_seen
FROM ({pairs}) one
WHERE score > 0
"""

COLLAPSED_PART = """
INSERT INTO link_part (a_user_id, b_user_id, signal, value, people, score, first_seen, last_seen)
SELECT DISTINCT ON (a_user_id, b_user_id)
       a_user_id, b_user_id, %(name)s, value, people, score, first_seen, last_seen
FROM ({pairs}) one
WHERE score > 0
ORDER BY a_user_id, b_user_id, score DESC
"""

MANY = """
INSERT INTO link_part (a_user_id, b_user_id, signal, value, people, score, first_seen, last_seen)
SELECT a_user_id, b_user_id, %(name)s, count(DISTINCT value)::text || ' addresses', NULL,
       %(weight)s::numeric, min(first_seen), max(last_seen)
FROM link_part
WHERE signal = %(stable)s
GROUP BY a_user_id, b_user_id
HAVING count(DISTINCT value) >= 2
"""

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

AGAINST = """
UPDATE link_pass p
SET score = round(p.score + %(weight)s::numeric, 3),
    families = p.families || jsonb_build_object('against', %(weight)s::numeric)
WHERE EXISTS (
    SELECT 1
    FROM fd.login_event a
    JOIN fd.login_event b
      ON b.user_id = p.b_user_id
     AND b.at >= date_trunc('hour', a.at)
     AND b.at < date_trunc('hour', a.at) + interval '1 hour'
    LEFT JOIN fd.ip_network na ON na.ip_prefix = a.ip_prefix
    LEFT JOIN fd.ip_network nb ON nb.ip_prefix = b.ip_prefix
    WHERE a.user_id = p.a_user_id
      AND coalesce(a.country, na.country) <> coalesce(b.country, nb.country)
      AND coalesce(na.class, 'stable') NOT IN ('vpn', 'hosting', 'tor')
      AND coalesce(nb.class, 'stable') NOT IN ('vpn', 'hosting', 'tor')
)
"""

BELOW_FLOOR = "DELETE FROM link_pass WHERE score < %(floor)s"

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


def signals(held=None):
    held = held or links.catalogue()
    found = {name: {**one, "family": NETWORK} for name, one in held["network_signals"].items()}
    found.update({name: {**one, "family": DEVICE} for name, one in held["device_signals"].items()})
    found.update({name: one for name, one in links.signals(held).items()
                  if one["family"] != NETWORK})
    return found


def against(held=None):
    return (held or links.catalogue())["against"]


def family_table(held):
    caps = families(held)
    rows = [(name, one["family"], caps[one["family"]]["cap"], bool(one.get("corroborating")))
            for name, one in signals(held).items()]
    return {"signals": [row[0] for row in rows], "families": [row[1] for row in rows],
            "caps": [row[2] for row in rows], "corroborating": [row[3] for row in rows]}


def evidence(name, settings, sightings):
    if name == links.JOINED_TOGETHER:
        return links.TOGETHER_SQL, {"weight": settings["weight"], "ceiling": settings["crowd_ceiling"],
                                    "window": settings.get("window_seconds", 300)}
    source = NETWORK_EVIDENCE.get(name) or DEVICE_EVIDENCE.get(name) or links.EVIDENCE.get(name)
    if source is None:
        return None, None
    pairs = links.PAIRS_SQL.format(
        evidence=source.format(sightings=sightings, shortest=SHORTEST_AGENT))
    return pairs, {"weight": settings["weight"], "ceiling": settings["crowd_ceiling"]}


def gather(conn, held):
    conn.execute(links.RARITY)
    conn.execute(links.STAGE)
    conn.execute(SIGHTING)
    sightings = int(links.shared(held).get("min_sightings", 1))
    counted = {}

    for name, settings in signals(held).items():
        pairs, args = evidence(name, settings, sightings)
        if pairs is None:
            continue
        template = COLLAPSED_PART if name in COLLAPSED else PART
        sql = template.format(pairs=pairs.replace("rarity(", "pg_temp.rarity("))
        with conn.cursor() as cur:
            cur.execute(sql, {**args, "name": name})
            counted[name] = cur.rowcount

    many = signals(held).get(IP_MANY)
    if many:
        with conn.cursor() as cur:
            cur.execute(MANY, {"name": IP_MANY, "weight": many["weight"], "stable": IP_STABLE})
            counted[IP_MANY] = cur.rowcount
    return counted


def run(conn):
    held = links.catalogue()
    marks = links.scoring(held)

    with ingest_run(conn, SOURCE) as counts:
        put_aside = links.mark_shared(conn, held)
        found = gather(conn, held)
        with conn.cursor() as cur:
            cur.execute(PASS, {**family_table(held), "floor": marks["floor"]})
            cur.execute(PASS_INDEX)
            cur.execute(AGAINST, {"weight": against(held)[TWO_COUNTRIES]["weight"]})
            countered = cur.rowcount
            cur.execute(BELOW_FLOOR, {"floor": marks["floor"]})
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
          f"{countered} lowered by activity in two countries, "
          f"{put_aside} address(es) on shared networks treated as rotating ({per_signal})")
    return changed
