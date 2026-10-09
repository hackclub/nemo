import yaml

from lib.db import ingest_run
from lib.paths import DB_DIR

SOURCE = "member_links"
SIGNALS_FILE = DB_DIR / "alt_signals.yml"

IP_EXACT = "ip_exact"
IP_PREFIX = "ip_prefix"
EMAIL_DOMAIN = "email_domain"
SESSION_AGENT = "session_agent"
JOINED_TOGETHER = "joined_together"

EVIDENCE = {
    IP_EXACT: """
        SELECT user_id, host(ip) AS value, min(at) AS first_seen, max(at) AS last_seen
        FROM fd.login_event e
        WHERE ip IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM shared_ip s WHERE s.ip = e.ip)
        GROUP BY 1, 2
        HAVING count(*) >= {sightings}
    """,
    IP_PREFIX: """
        SELECT user_id, host(ip_prefix) AS value, min(at) AS first_seen, max(at) AS last_seen
        FROM fd.login_event e
        WHERE ip_prefix IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM shared_ip s WHERE s.ip = e.ip)
        GROUP BY 1, 2
        HAVING count(*) >= {sightings}
    """,
    EMAIL_DOMAIN: """
        SELECT user_id, lower(split_part(email, '@', 2)) AS value,
               NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM fd.member_identity
        WHERE email IS NOT NULL AND position('@' IN email) > 0
    """,
    SESSION_AGENT: """
        SELECT user_id, ua_app || ' / ' || ua_os AS value,
               min(at) AS first_seen, max(at) AS last_seen
        FROM fd.login_event
        WHERE ua_app IS NOT NULL AND ua_os IS NOT NULL GROUP BY 1, 2
    """,
}

PAIRS_SQL = """
WITH ev AS ({evidence}),
crowd AS (
    SELECT value, count(DISTINCT user_id) AS people FROM ev GROUP BY 1
),
keep AS (
    SELECT value, people FROM crowd WHERE people BETWEEN 2 AND %(ceiling)s
),
small AS (
    SELECT e.user_id, e.value, e.first_seen, e.last_seen
    FROM ev e JOIN keep k ON k.value = e.value
),
whole AS (
    SELECT greatest(count(DISTINCT user_id), 2)::numeric AS people FROM ev
)
SELECT least(a.user_id, b.user_id) AS a_user_id,
       greatest(a.user_id, b.user_id) AS b_user_id,
       a.value,
       k.people,
       %(weight)s::numeric * rarity((SELECT people FROM whole), k.people) AS score,
       least(a.first_seen, b.first_seen) AS first_seen,
       greatest(a.last_seen, b.last_seen) AS last_seen
FROM small a
JOIN small b ON b.value = a.value AND b.user_id > a.user_id
JOIN keep k ON k.value = a.value
"""

TOGETHER_SQL = """
WITH ev AS (
    SELECT user_id, joined_at, date_trunc('hour', joined_at) AS bucket
    FROM fd.member_joins WHERE joined_at IS NOT NULL
),
crowd AS (
    SELECT bucket, count(DISTINCT user_id) AS people FROM ev GROUP BY 1
),
keep AS (
    SELECT bucket, people FROM crowd WHERE people BETWEEN 2 AND %(ceiling)s
),
small AS (
    SELECT e.user_id, e.joined_at, e.bucket FROM ev e JOIN keep k ON k.bucket = e.bucket
),
whole AS (
    SELECT greatest(count(DISTINCT user_id), 2)::numeric AS people FROM ev
)
SELECT least(a.user_id, b.user_id) AS a_user_id,
       greatest(a.user_id, b.user_id) AS b_user_id,
       to_char(least(a.joined_at, b.joined_at), 'YYYY-MM-DD HH24:MI') AS value,
       k.people,
       %(weight)s::numeric * rarity((SELECT people FROM whole), k.people) AS score,
       least(a.joined_at, b.joined_at) AS first_seen,
       greatest(a.joined_at, b.joined_at) AS last_seen
FROM small a
JOIN small b ON b.bucket = a.bucket AND b.user_id > a.user_id
            AND b.joined_at BETWEEN a.joined_at - make_interval(secs => %(window)s)
                                AND a.joined_at + make_interval(secs => %(window)s)
JOIN keep k ON k.bucket = a.bucket
"""

SHARED_ISP = """
CREATE TEMP TABLE shared_isp ON COMMIT DROP AS
SELECT isp,
       count(DISTINCT ip)::numeric / greatest(count(DISTINCT user_id), 1) AS ips_each,
       count(DISTINCT user_id) AS people
FROM fd.login_event
WHERE isp IS NOT NULL
GROUP BY isp
HAVING count(DISTINCT ip)::numeric / greatest(count(DISTINCT user_id), 1) >= %(rotates)s
    OR count(DISTINCT user_id) >= %(crowds)s
"""

SHARED_IP = """
CREATE TEMP TABLE shared_ip ON COMMIT DROP AS
SELECT DISTINCT e.ip
FROM fd.login_event e
JOIN shared_isp s ON s.isp = e.isp
WHERE e.ip IS NOT NULL
"""

SHARED_INDEX = "CREATE INDEX ON shared_ip (ip)"

RARITY = """
CREATE OR REPLACE FUNCTION pg_temp.rarity(whole numeric, crowd numeric)
RETURNS numeric AS $$
    SELECT CASE
        WHEN whole <= 2 OR crowd <= 1 THEN 1::numeric
        WHEN crowd >= whole THEN 0::numeric
        ELSE least(1, greatest(0, ln(whole / crowd) / ln(whole / 2)))
    END
$$ LANGUAGE sql IMMUTABLE
"""

STAGE = """
CREATE TEMP TABLE link_part (
    a_user_id text, b_user_id text, signal text, value text,
    people integer, score numeric, first_seen timestamptz, last_seen timestamptz
) ON COMMIT DROP
"""

LAND = """
INSERT INTO fd.member_link
    (a_user_id, b_user_id, score, top_signal, signals, first_seen, last_seen, computed_at)
SELECT a_user_id,
       b_user_id,
       round(sum(score)::numeric, 3),
       (array_agg(signal ORDER BY score DESC))[1],
       jsonb_object_agg(signal, jsonb_build_object(
           'value', value, 'people', people, 'score', round(score::numeric, 3))),
       min(first_seen),
       max(last_seen),
       now()
FROM (
    SELECT DISTINCT ON (a_user_id, b_user_id, signal)
           a_user_id, b_user_id, signal, value, people, score, first_seen, last_seen
    FROM link_part
    ORDER BY a_user_id, b_user_id, signal, score DESC
) best
GROUP BY a_user_id, b_user_id
HAVING sum(score) >= %(floor)s
   AND count(*) FILTER (WHERE NOT (signal = ANY (%(corroborating)s))) > 0
ON CONFLICT (a_user_id, b_user_id) DO UPDATE SET
    score = EXCLUDED.score,
    top_signal = EXCLUDED.top_signal,
    signals = EXCLUDED.signals,
    first_seen = EXCLUDED.first_seen,
    last_seen = EXCLUDED.last_seen,
    computed_at = EXCLUDED.computed_at
"""

SWEEP = "DELETE FROM fd.member_link WHERE computed_at < %s"


def catalogue():
    return yaml.safe_load(SIGNALS_FILE.read_text())


def scoring(held=None):
    return (held or catalogue())["scoring"]


def signals(held=None):
    return (held or catalogue())["signals"]


def corroborating(held=None):
    return [name for name, one in signals(held).items() if one.get("corroborating")]


def shared(held=None):
    return (held or catalogue()).get("shared_networks", {})


def mark_shared(conn, held):
    settings = shared(held)
    conn.execute(SHARED_ISP, {"rotates": settings.get("rotates_above", 5.0),
                              "crowds": settings.get("crowds_above", 40)})
    conn.execute(SHARED_IP)
    conn.execute(SHARED_INDEX)
    row = conn.execute("SELECT count(*) FROM shared_ip").fetchone()
    return row[0] if row else 0


def gather(conn, held):
    conn.execute(RARITY)
    conn.execute(STAGE)
    sightings = int(shared(held).get("min_sightings", 1))
    counted = {}

    for name, settings in signals(held).items():
        if name == JOINED_TOGETHER:
            sql = TOGETHER_SQL
            args = {"weight": settings["weight"], "ceiling": settings["crowd_ceiling"],
                    "window": settings.get("window_seconds", 300)}
        else:
            source = EVIDENCE.get(name)
            if source is None:
                continue
            sql = PAIRS_SQL.format(evidence=source.format(sightings=sightings))
            args = {"weight": settings["weight"], "ceiling": settings["crowd_ceiling"]}

        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO link_part "
                "(a_user_id, b_user_id, signal, value, people, score, first_seen, last_seen) "
                f"SELECT a_user_id, b_user_id, '{name}', value, people, score, "
                "first_seen, last_seen FROM ("
                + sql.replace("rarity(", "pg_temp.rarity(")
                + ") one WHERE score > 0",
                args,
            )
            counted[name] = cur.rowcount

    return counted


def run(conn):
    held = catalogue()
    marks = scoring(held)

    with ingest_run(conn, SOURCE) as counts:
        started = conn.execute("SELECT now()").fetchone()[0]
        put_aside = mark_shared(conn, held)
        found = gather(conn, held)
        with conn.cursor() as cur:
            cur.execute(LAND, {"floor": marks["floor"],
                               "corroborating": corroborating(held)})
            counts.rows_in = cur.rowcount
            cur.execute(SWEEP, (started,))
            gone = cur.rowcount
        conn.commit()

    per_signal = ", ".join(f"{name} {n}" for name, n in sorted(found.items()) if n)
    print(f"{SOURCE}: {counts.rows_in} link(s) kept, {gone} dropped, "
          f"{put_aside} address(es) on shared networks left out ({per_signal})")
    return counts.rows_in
