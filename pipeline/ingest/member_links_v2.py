import re
import time

from ingest import member_links as links
from lib.db import ingest_run
from lib.mailbox import mailbox, staff_domain

SOURCE = "member_links_v2"
NETWORK = "network"
DEVICE = "device"
IDENTITY = "identity"
NAME = "name"
ARRIVAL = "arrival"
SHORTEST_LOCAL = 4
SHORTEST_NAME = 3
SHORTEST_LONG_STEM = 8
DEVICE_AGENT = "device_agent"
DEVICE_JA4 = "device_ja4"
SHORTEST_AGENT = 20
IP_STABLE = "ip_stable"
IP_SAME_HOUR = "ip_same_hour"
IP_MANY = "ip_many"
IP_HOURLY = "ip_hourly"
IP_PREFIX_STABLE = "ip_prefix_stable"
IP_SHARED_EXIT = "ip_shared_exit"
IP_SHARED_EXITS = "ip_shared_exits"
REPEATED = ((IP_MANY, IP_STABLE), (IP_SHARED_EXITS, IP_SHARED_EXIT))
COLLAPSED = (IP_SAME_HOUR, IP_HOURLY)
TWO_COUNTRIES = "two_countries"

SIGHTING = """
CREATE TEMP TABLE sighting ON COMMIT DROP AS
SELECT e.user_id, e.ip, e.ip_prefix, date_trunc('hour', e.at) AS hour, count(*) AS seen,
       CASE WHEN n.class IN ('rotating', 'vpn', 'hosting', 'tor') THEN n.class
            WHEN EXISTS (SELECT 1 FROM shared_ip s WHERE s.ip = e.ip) THEN 'rotating'
            ELSE 'stable' END AS class,
       coalesce(e.country, n.country) AS country
FROM fd.login_event e
LEFT JOIN fd.ip_network n ON n.ip_prefix = e.ip_prefix
WHERE e.ip IS NOT NULL
GROUP BY e.user_id, e.ip, e.ip_prefix, date_trunc('hour', e.at), n.class,
         coalesce(e.country, n.country)
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
    IP_SHARED_EXIT: """
        SELECT user_id, host(ip) AS value, min(hour) AS first_seen, max(hour) AS last_seen
        FROM sighting
        WHERE class IN ('vpn', 'hosting', 'tor')
        GROUP BY 1, 2
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

MAILBOX = """
CREATE TEMP TABLE mailbox (user_id text, box text, local text, domain text) ON COMMIT DROP
"""

STAFF = """
CREATE TEMP TABLE staff_member (user_id text PRIMARY KEY) ON COMMIT DROP
"""

IDENTITIES_SQL = """
SELECT user_id, email FROM fd.member_identity
WHERE email IS NOT NULL AND position('@' IN email) > 0
"""

IDENTITY_EVIDENCE = {
    "mailbox_alias": """
        SELECT user_id, box AS value, NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM mailbox
    """,
    "local_part": """
        SELECT user_id, local AS value, NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM mailbox
        WHERE length(local) >= {shortest_local}
    """,
}

NAME_EVIDENCE = {
    "full_name": """
        SELECT i.user_id, lower(btrim(i.real_name)) AS value,
               NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM fd.member_identity i
        JOIN fd.member m ON m.user_id = i.user_id
        WHERE NOT m.is_bot AND length(btrim(coalesce(i.real_name, ''))) >= {shortest_name}
          AND position('deactivateduser' IN lower(i.real_name)) <> 1
    """,
    "display_name": """
        SELECT user_id, lower(btrim(display_name)) AS value,
               NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM fd.member
        WHERE NOT is_bot AND length(btrim(coalesce(display_name, ''))) >= {shortest_name}
          AND position('deactivateduser' IN lower(display_name)) <> 1
    """,
    "handle_stem": """
        SELECT user_id, regexp_replace(lower(handle), '[^a-z]+$', '') AS value,
               NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM fd.member
        WHERE NOT is_bot AND handle IS NOT NULL
          AND position('deactivateduser' IN lower(handle)) <> 1
          AND length(regexp_replace(lower(handle), '[^a-z]+$', '')) >= {shortest_name}
    """,
    "handle_stem_long": """
        SELECT user_id, regexp_replace(lower(handle), '[^a-z]+$', '') AS value,
               NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM fd.member
        WHERE NOT is_bot AND handle IS NOT NULL
          AND position('deactivateduser' IN lower(handle)) <> 1
          AND length(regexp_replace(lower(handle), '[^a-z]+$', '')) >= {longest_stem}
    """,
}

BANNED = """
WITH banned AS (
    SELECT entity_id AS user_id,
           max(at) FILTER (WHERE action = 'user_deactivated') AS banned_at,
           max(at) FILTER (WHERE action = 'user_reactivated') AS back_at
    FROM slack.audit_event
    WHERE action IN ('user_deactivated', 'user_reactivated') AND entity_id IS NOT NULL
    GROUP BY 1
),
held AS (
    SELECT user_id, banned_at FROM banned
    WHERE banned_at IS NOT NULL AND banned_at > coalesce(back_at, '-infinity'::timestamptz)
)"""

ARRIVAL_EVIDENCE = {
    "created_same_address": """
        WITH ev AS (
            SELECT e.user_id, e.ip, min(j.joined_at) AS at
            FROM fd.login_event e
            JOIN fd.member_joins j ON j.user_id = e.user_id
            WHERE e.ip IS NOT NULL
              AND e.at BETWEEN j.joined_at - interval '5 minutes' AND j.joined_at + interval '1 hour'
            GROUP BY 1, 2
        ),
        crowd AS (
            SELECT ip, count(DISTINCT user_id) AS people FROM ev GROUP BY 1
        ),
        keep AS (
            SELECT ip, people FROM crowd WHERE people BETWEEN 2 AND %(ceiling)s
        )
        SELECT least(a.user_id, b.user_id) AS a_user_id,
               greatest(a.user_id, b.user_id) AS b_user_id,
               host(a.ip) AS value, k.people, %(weight)s::numeric AS score,
               least(a.at, b.at) AS first_seen, greatest(a.at, b.at) AS last_seen
        FROM ev a
        JOIN keep k ON k.ip = a.ip
        JOIN ev b ON b.ip = a.ip AND b.user_id > a.user_id
                 AND b.at BETWEEN a.at - make_interval(secs => %(window)s)
                              AND a.at + make_interval(secs => %(window)s)
    """,
    "invited_by": """
        WITH invites AS (
            SELECT actor_id, entity_id, min(at) AS at
            FROM slack.audit_event
            WHERE action = 'user_created' AND actor_id IS NOT NULL AND entity_id IS NOT NULL
              AND actor_id <> entity_id
            GROUP BY 1, 2
        ),
        crowd AS (
            SELECT actor_id, count(*) AS people FROM invites GROUP BY 1
        ),
        whole AS (
            SELECT greatest(count(*), 2)::numeric AS people FROM invites
        )
        SELECT least(i.actor_id, i.entity_id) AS a_user_id,
               greatest(i.actor_id, i.entity_id) AS b_user_id,
               i.actor_id AS value, c.people,
               %(weight)s::numeric * rarity((SELECT people FROM whole), (c.people + 1)::numeric) AS score,
               i.at AS first_seen, i.at AS last_seen
        FROM invites i
        JOIN crowd c ON c.actor_id = i.actor_id
        WHERE c.people <= %(ceiling)s
    """,
    "after_ban_address": BANNED + """,
        used AS (
            SELECT DISTINCT s.user_id, s.ip, h.banned_at
            FROM sighting s
            JOIN held h ON h.user_id = s.user_id
            WHERE s.class = 'stable' AND s.hour <= h.banned_at
        ),
        crowd AS (
            SELECT ip, count(DISTINCT user_id) AS people
            FROM sighting WHERE ip IN (SELECT ip FROM used) GROUP BY 1
        ),
        arrived AS (
            SELECT user_id, ip, min(hour) AS first_at
            FROM sighting WHERE ip IN (SELECT ip FROM used) GROUP BY 1, 2
        )
        SELECT least(u.user_id, a.user_id) AS a_user_id,
               greatest(u.user_id, a.user_id) AS b_user_id,
               host(u.ip) AS value, c.people, %(weight)s::numeric AS score,
               u.banned_at AS first_seen, a.first_at AS last_seen
        FROM used u
        JOIN crowd c ON c.ip = u.ip AND c.people <= %(ceiling)s
        JOIN arrived a ON a.ip = u.ip AND a.user_id <> u.user_id AND a.first_at > u.banned_at
    """,
    "after_ban_device": BANNED + """,
        agent AS (
            SELECT user_id, ua, min(at) AS first_at
            FROM fd.login_event
            WHERE ua IS NOT NULL AND length(ua) >= {shortest}
            GROUP BY 1, 2
        ),
        crowd AS (
            SELECT ua, count(*) AS people FROM agent GROUP BY 1
            HAVING count(*) BETWEEN 2 AND %(ceiling)s
        ),
        used AS (
            SELECT a.user_id, a.ua, h.banned_at
            FROM agent a
            JOIN held h ON h.user_id = a.user_id
            JOIN crowd c ON c.ua = a.ua
            WHERE a.first_at <= h.banned_at
        )
        SELECT least(u.user_id, b.user_id) AS a_user_id,
               greatest(u.user_id, b.user_id) AS b_user_id,
               u.ua AS value, c.people, %(weight)s::numeric AS score,
               u.banned_at AS first_seen, b.first_at AS last_seen
        FROM used u
        JOIN crowd c ON c.ua = u.ua
        JOIN agent b ON b.ua = u.ua AND b.user_id <> u.user_id AND b.first_at > u.banned_at
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
WHERE signal = %(single)s
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
),
named AS (
    SELECT b.a_user_id, b.b_user_id,
           jsonb_object_agg(b.signal, jsonb_build_object(
               'value', b.value, 'people', b.people, 'score', round(b.score::numeric, 3))) AS signals
    FROM best b
    JOIN pair p ON p.a_user_id = b.a_user_id AND p.b_user_id = b.b_user_id
    GROUP BY b.a_user_id, b.b_user_id
)
SELECT p.a_user_id, p.b_user_id, p.score, p.top_family, p.families, n.signals,
       p.first_seen, p.last_seen, NULL::text AS label
FROM pair p
JOIN named n ON n.a_user_id = p.a_user_id AND n.b_user_id = p.b_user_id
"""

PASS_INDEX = "CREATE INDEX ON link_pass (a_user_id, b_user_id)"

PRESENCE = """
CREATE TEMP TABLE presence ON COMMIT DROP AS
SELECT DISTINCT s.user_id, s.hour, s.country
FROM sighting s
WHERE s.country IS NOT NULL
  AND s.class NOT IN ('vpn', 'hosting', 'tor')
  AND s.user_id IN (SELECT a_user_id FROM link_pass UNION SELECT b_user_id FROM link_pass)
"""

PRESENCE_INDEX = "CREATE INDEX ON presence (user_id, hour)"

AGAINST = """
UPDATE link_pass p
SET score = round(p.score + %(weight)s::numeric, 3),
    families = p.families || jsonb_build_object('against', %(weight)s::numeric)
FROM (
    SELECT DISTINCT l.a_user_id, l.b_user_id
    FROM link_pass l
    JOIN presence a ON a.user_id = l.a_user_id
    JOIN presence b ON b.user_id = l.b_user_id AND b.hour = a.hour AND b.country <> a.country
) clash
WHERE clash.a_user_id = p.a_user_id AND clash.b_user_id = p.b_user_id
"""

STAFF_TEST = """
UPDATE link_pass p
SET label = 'staff_test'
WHERE p.label IS NULL
  AND EXISTS (SELECT 1 FROM staff_member s WHERE s.user_id = p.a_user_id)
  AND EXISTS (SELECT 1 FROM staff_member s WHERE s.user_id = p.b_user_id)
"""

CLASSROOM = """
UPDATE link_pass p
SET label = 'classroom',
    score = round(p.score + %(weight)s::numeric, 3),
    families = p.families || jsonb_build_object('classroom', %(weight)s::numeric)
WHERE p.label IS NULL
  AND (EXISTS (
          SELECT 1 FROM fd.ip_network n
          WHERE p.signals ? 'ip_stable'
            AND n.ip_prefix = network(set_masklen((p.signals->'ip_stable'->>'value')::inet,
                CASE WHEN family((p.signals->'ip_stable'->>'value')::inet) = 4 THEN 24 ELSE 64 END))
            AND n.network ~* %(networks)s)
       OR coalesce(p.signals->'device_agent'->>'value', '') ~ %(devices)s)
"""

HOUSEHOLD = """
UPDATE link_pass p
SET label = 'household',
    score = round(p.score + %(weight)s::numeric, 3),
    families = p.families || jsonb_build_object('household', %(weight)s::numeric)
FROM fd.member_identity a, fd.member_identity b
WHERE p.label IS NULL
  AND p.signals ? 'ip_stable'
  AND a.user_id = p.a_user_id AND b.user_id = p.b_user_id
  AND position(' ' IN btrim(a.real_name)) > 0 AND position(' ' IN btrim(b.real_name)) > 0
  AND regexp_replace(lower(btrim(a.real_name)), '^.*[[:space:]]', '')
      = regexp_replace(lower(btrim(b.real_name)), '^.*[[:space:]]', '')
  AND split_part(lower(btrim(a.real_name)), ' ', 1) <> split_part(lower(btrim(b.real_name)), ' ', 1)
"""

BELOW_FLOOR = "DELETE FROM link_pass WHERE score < %(floor)s"

LAND = """
INSERT INTO fd.member_link_v2
    (a_user_id, b_user_id, score, top_family, families, signals, first_seen, last_seen, label,
     computed_at)
SELECT a_user_id, b_user_id, score, top_family, families, signals, first_seen, last_seen, label, now()
FROM link_pass
ON CONFLICT (a_user_id, b_user_id) DO UPDATE SET
    score = EXCLUDED.score,
    top_family = EXCLUDED.top_family,
    families = EXCLUDED.families,
    signals = EXCLUDED.signals,
    first_seen = EXCLUDED.first_seen,
    last_seen = EXCLUDED.last_seen,
    label = EXCLUDED.label,
    computed_at = EXCLUDED.computed_at
WHERE (fd.member_link_v2.score, fd.member_link_v2.top_family, fd.member_link_v2.families,
       fd.member_link_v2.signals, fd.member_link_v2.first_seen, fd.member_link_v2.last_seen,
       fd.member_link_v2.label)
      IS DISTINCT FROM (EXCLUDED.score, EXCLUDED.top_family, EXCLUDED.families,
                        EXCLUDED.signals, EXCLUDED.first_seen, EXCLUDED.last_seen, EXCLUDED.label)
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
    found.update({name: {**one, "family": IDENTITY} for name, one in held["identity_signals"].items()})
    found.update({name: {**one, "family": NAME} for name, one in held["name_signals"].items()})
    found.update({name: {**one, "family": ARRIVAL} for name, one in held["arrival_signals"].items()})
    found.update({name: one for name, one in links.signals(held).items()
                  if one["family"] != NETWORK})
    return found


def against(held=None):
    return (held or links.catalogue())["against"]


def labels(held=None):
    return (held or links.catalogue())["labels"]


def pattern(words):
    if not words:
        return "a^"
    return "(" + "|".join(re.escape(word) for word in words) + ")"


def staff_members(identities, staff):
    for user_id, email in identities:
        box = mailbox(email)
        if box and staff_domain(box.rpartition("@")[2], staff):
            yield (user_id,)


def family_table(held):
    caps = families(held)
    rows = [(name, one["family"], caps[one["family"]]["cap"], bool(one.get("corroborating")))
            for name, one in signals(held).items()]
    return {"signals": [row[0] for row in rows], "families": [row[1] for row in rows],
            "caps": [row[2] for row in rows], "corroborating": [row[3] for row in rows]}


def evidence(name, settings, sightings):
    if name in ARRIVAL_EVIDENCE:
        return ARRIVAL_EVIDENCE[name].format(shortest=SHORTEST_AGENT), {
            "weight": settings["weight"], "ceiling": settings["crowd_ceiling"],
            "window": settings.get("window_seconds", 1800)}
    if name == links.JOINED_TOGETHER:
        return links.TOGETHER_SQL, {"weight": settings["weight"], "ceiling": settings["crowd_ceiling"],
                                    "window": settings.get("window_seconds", 300)}
    source = (NETWORK_EVIDENCE.get(name) or DEVICE_EVIDENCE.get(name)
              or IDENTITY_EVIDENCE.get(name) or NAME_EVIDENCE.get(name) or links.EVIDENCE.get(name))
    if source is None:
        return None, None
    pairs = links.PAIRS_SQL.format(
        evidence=source.format(sightings=sightings, shortest=SHORTEST_AGENT,
                               shortest_local=SHORTEST_LOCAL, shortest_name=SHORTEST_NAME,
                               longest_stem=SHORTEST_LONG_STEM))
    return pairs, {"weight": settings["weight"], "ceiling": settings["crowd_ceiling"]}


def mailbox_rows(identities, staff):
    for user_id, email in identities:
        box = mailbox(email)
        if box is None:
            continue
        local, _, domain = box.rpartition("@")
        if staff_domain(domain, staff):
            continue
        yield user_id, box, local, domain


def load_mailboxes(conn, held):
    conn.execute(MAILBOX)
    staff = held.get("staff_domains", [])
    identities = conn.execute(IDENTITIES_SQL).fetchall()
    with conn.cursor() as cur, cur.copy("COPY mailbox (user_id, box, local, domain) FROM STDIN") as copy:
        for row in mailbox_rows(identities, staff):
            copy.write_row(row)
    conn.execute(STAFF)
    with conn.cursor() as cur, cur.copy("COPY staff_member (user_id) FROM STDIN") as copy:
        for row in staff_members(identities, staff):
            copy.write_row(row)


def gather(conn, held):
    conn.execute(links.RARITY)
    conn.execute(links.STAGE)
    conn.execute(SIGHTING)
    conn.execute("ANALYZE sighting")
    load_mailboxes(conn, held)
    conn.execute("ANALYZE mailbox")
    conn.execute("ANALYZE staff_member")
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

    for name, single in REPEATED:
        many = signals(held).get(name)
        if many:
            with conn.cursor() as cur:
                cur.execute(MANY, {"name": name, "weight": many["weight"], "single": single})
                counted[name] = cur.rowcount
    return counted


def run(conn):
    held = links.catalogue()
    marks = links.scoring(held)

    took = {}
    clock = time.monotonic()

    def lap(step):
        nonlocal clock
        now = time.monotonic()
        took[step] = now - clock
        clock = now

    with ingest_run(conn, SOURCE) as counts:
        put_aside = links.mark_shared(conn, held)
        conn.execute("ANALYZE shared_ip")
        found = gather(conn, held)
        conn.execute("ANALYZE link_part")
        lap("gather")
        with conn.cursor() as cur:
            cur.execute(PASS, {**family_table(held), "floor": marks["floor"]})
            cur.execute(PASS_INDEX)
            cur.execute("ANALYZE link_pass")
            lap("score")
            cur.execute(PRESENCE)
            cur.execute(PRESENCE_INDEX)
            cur.execute("ANALYZE presence")
            cur.execute(AGAINST, {"weight": against(held)[TWO_COUNTRIES]["weight"]})
            countered = cur.rowcount
            lap("countries")
            named = labels(held)
            labelled = {}
            cur.execute(STAFF_TEST)
            labelled["staff_test"] = cur.rowcount
            cur.execute(CLASSROOM, {"weight": named["classroom"]["weight"],
                                    "networks": pattern(named["classroom"].get("networks")),
                                    "devices": pattern(named["classroom"].get("devices"))})
            labelled["classroom"] = cur.rowcount
            cur.execute(HOUSEHOLD, {"weight": named["household"]["weight"]})
            labelled["household"] = cur.rowcount
            lap("labels")
            cur.execute(BELOW_FLOOR, {"floor": marks["floor"]})
            cur.execute(LAND)
            changed = cur.rowcount
            cur.execute(SWEEP)
            gone = cur.rowcount
            cur.execute("SELECT count(*) FROM link_pass")
            kept = cur.fetchone()[0]
        conn.commit()
        lap("write")
        counts.rows_in = changed

    per_signal = ", ".join(f"{name} {n}" for name, n in sorted(found.items()) if n)
    per_label = ", ".join(f"{count} labelled {name}" for name, count in labelled.items())
    print(f"{SOURCE}: {kept} link(s) kept, {changed} written, {gone} dropped, "
          f"{countered} lowered by activity in two countries, {per_label}, "
          f"{put_aside} address(es) on shared networks treated as rotating ({per_signal})")
    print(f"{SOURCE}: took " + ", ".join(f"{step} {seconds:.0f}s" for step, seconds in took.items()))
    return changed
