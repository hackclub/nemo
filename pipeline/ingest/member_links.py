import re
import time

import yaml

from lib.db import ingest_run
from lib.mailbox import mailbox, staff_domain
from lib.paths import DB_DIR

SOURCE = "member_links"
SIGNALS_FILE = DB_DIR / "alt_signals.yml"

EMAIL_DOMAIN = "email_domain"
SESSION_AGENT = "session_agent"
JOINED_TOGETHER = "joined_together"

EVIDENCE = {
    EMAIL_DOMAIN: """
        SELECT user_id, lower(split_part(email, '@', 2)) AS value,
               NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM {identity}
        WHERE email IS NOT NULL AND position('@' IN email) > 0
    """,
    SESSION_AGENT: """
        SELECT e.user_id, u.app || ' / ' || u.os AS value,
               min(e.first_at) AS first_seen, max(e.last_at) AS last_seen
        FROM {login} e
        JOIN slack.user_agent u ON u.id = e.ua_id
        WHERE u.app IS NOT NULL AND u.os IS NOT NULL GROUP BY 1, 2
    """,
}

PAIRS_SQL = """
WITH ev AS ({evidence}),
crowd AS (
    SELECT value, count(DISTINCT user_id) AS people FROM ev GROUP BY 1
),
keep AS (
    SELECT value, people FROM crowd WHERE people BETWEEN 2 AND %(ceiling)s {not_crowded_value}
),
small AS (
    SELECT e.user_id, e.value, e.first_seen, e.last_seen
    FROM ev e JOIN keep k ON k.value = e.value
)
SELECT least(a.user_id, b.user_id) AS a_user_id,
       greatest(a.user_id, b.user_id) AS b_user_id,
       a.value,
       k.people,
       %(weight)s::numeric * rarity(%(whole)s::numeric, k.people) AS score,
       least(a.first_seen, b.first_seen) AS first_seen,
       greatest(a.last_seen, b.last_seen) AS last_seen
FROM small a
JOIN small b ON b.value = a.value AND b.user_id > a.user_id
JOIN keep k ON k.value = a.value
"""

WHOLE_SQL = """
WITH ev AS ({evidence})
SELECT greatest(count(DISTINCT user_id), 2)::numeric FROM ev
"""

TOGETHER_EVIDENCE = """
    SELECT user_id, joined_at, date_trunc('hour', joined_at) AS bucket
    FROM {joins} WHERE joined_at IS NOT NULL
"""

TOGETHER_SQL = """
WITH ev AS (""" + TOGETHER_EVIDENCE + """),
crowd AS (
    SELECT bucket, count(DISTINCT user_id) AS people FROM ev GROUP BY 1
),
keep AS (
    SELECT bucket, people FROM crowd WHERE people BETWEEN 2 AND %(ceiling)s
),
small AS (
    SELECT e.user_id, e.joined_at, e.bucket FROM ev e JOIN keep k ON k.bucket = e.bucket
)
SELECT least(a.user_id, b.user_id) AS a_user_id,
       greatest(a.user_id, b.user_id) AS b_user_id,
       to_char(least(a.joined_at, b.joined_at), 'YYYY-MM-DD HH24:MI') AS value,
       k.people,
       %(weight)s::numeric * rarity(%(whole)s::numeric, k.people) AS score,
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

KEEP_SHARED = """
WITH gone AS (DELETE FROM fd.shared_ip WHERE ip NOT IN (SELECT ip FROM shared_ip))
INSERT INTO fd.shared_ip (ip) SELECT ip FROM shared_ip ON CONFLICT (ip) DO NOTHING
"""

KEEP_WHOLE = """
INSERT INTO fd.link_signal_stat (signal, whole, computed_at)
SELECT signal, whole, now() FROM unnest(%s::text[], %s::numeric[]) AS one (signal, whole)
ON CONFLICT (signal) DO UPDATE SET whole = EXCLUDED.whole, computed_at = EXCLUDED.computed_at
"""

HELD_WHOLE = "SELECT signal, whole FROM fd.link_signal_stat"

QUIET = "SET LOCAL fd.quiet_links = 'on'"

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
IP_BURST = "ip_burst"
REPEATED = ((IP_MANY, IP_STABLE),)
COLLAPSED = (IP_SAME_HOUR, IP_HOURLY, IP_BURST)
TWO_COUNTRIES = "two_countries"

SIGHTING_SELECT = """
SELECT e.user_id, e.ip, e.ip_prefix, e.hour, sum(e.hits) AS seen,
       CASE WHEN n.class IN ('rotating', 'vpn', 'hosting', 'tor') THEN n.class
            WHEN EXISTS (SELECT 1 FROM {shared_ip} s WHERE s.ip = e.ip) THEN 'rotating'
            ELSE 'stable' END AS class,
       coalesce(e.country, n.country) AS country
FROM {login} e
LEFT JOIN fd.ip_network n ON n.ip_prefix = e.ip_prefix
WHERE e.ip IS NOT NULL
GROUP BY e.user_id, e.ip, e.ip_prefix, e.hour, n.class,
         coalesce(e.country, n.country)
"""

SIGHTING = "CREATE TEMP TABLE sighting ON COMMIT DROP AS" + SIGHTING_SELECT

NETWORK_EVIDENCE = {
    IP_STABLE: """
        SELECT s.user_id, host(s.ip) AS value, min(s.hour) AS first_seen, max(s.hour) AS last_seen
        FROM sighting s
        WHERE s.class = 'stable'
          AND s.ip_prefix IN (SELECT ip_prefix FROM sighting WHERE class = 'stable'
                              GROUP BY 1 HAVING count(DISTINCT user_id) <= {range_ceiling})
        GROUP BY 1, 2
        HAVING sum(s.seen) >= {sightings}
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
               host(e.ip) || ' ' || to_char(e.hour, 'YYYY-MM-DD HH24')
                   || ' ' || left(md5(u.ua), 12) AS value,
               min(e.first_at) AS first_seen, max(e.last_at) AS last_seen
        FROM {login} e
        JOIN slack.user_agent u ON u.id = e.ua_id
        LEFT JOIN fd.ip_network n ON n.ip_prefix = e.ip_prefix
        WHERE e.ip IS NOT NULL
          AND (n.class IN ('rotating', 'vpn', 'hosting', 'tor')
               OR EXISTS (SELECT 1 FROM {shared_ip} s WHERE s.ip = e.ip))
        GROUP BY 1, 2
    """,
}

DEVICE_EVIDENCE = {
    DEVICE_AGENT: """
        SELECT e.user_id, u.ua AS value, min(e.first_at) AS first_seen, max(e.last_at) AS last_seen
        FROM {login} e
        JOIN slack.user_agent u ON u.id = e.ua_id
        WHERE length(u.ua) >= {shortest}
        GROUP BY 1, 2
    """,
    DEVICE_JA4: """
        SELECT actor_id AS user_id, payload->'details'->>'client_ja4_fingerprint' AS value,
               min(at) AS first_seen, max(at) AS last_seen
        FROM {audit}
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
SELECT user_id, email FROM {identity}
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
        FROM {identity} i
        JOIN {member} m ON m.user_id = i.user_id
        WHERE NOT m.is_bot AND length(btrim(coalesce(i.real_name, ''))) >= {shortest_name}
          AND position('deactivateduser' IN lower(i.real_name)) <> 1
    """,
    "display_name": """
        SELECT user_id, lower(btrim(display_name)) AS value,
               NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM {member}
        WHERE NOT is_bot AND length(btrim(coalesce(display_name, ''))) >= {shortest_name}
          AND position('deactivateduser' IN lower(display_name)) <> 1
    """,
    "handle_stem": """
        SELECT user_id, regexp_replace(lower(handle), '[^a-z]+$', '') AS value,
               NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM {member}
        WHERE NOT is_bot AND handle IS NOT NULL
          AND position('deactivateduser' IN lower(handle)) <> 1
          AND length(regexp_replace(lower(handle), '[^a-z]+$', '')) >= {shortest_name}
    """,
    "handle_stem_long": """
        SELECT user_id, regexp_replace(lower(handle), '[^a-z]+$', '') AS value,
               NULL::timestamptz AS first_seen, NULL::timestamptz AS last_seen
        FROM {member}
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
    FROM {audit}
    WHERE action IN ('user_deactivated', 'user_reactivated') AND entity_id IS NOT NULL
    GROUP BY 1
),
held AS (
    SELECT user_id, banned_at FROM banned
    WHERE banned_at IS NOT NULL AND banned_at > coalesce(back_at, '-infinity'::timestamptz)
)"""

INVITES = """
    SELECT actor_id, entity_id, min(at) AS at
    FROM {audit}
    WHERE action = 'user_created' AND actor_id IS NOT NULL AND entity_id IS NOT NULL
      AND actor_id <> entity_id
    GROUP BY 1, 2
"""

INVITES_WHOLE = "SELECT greatest(count(*), 2)::numeric FROM (" + INVITES + ") invites"

TOGETHER_WHOLE = "SELECT greatest(count(DISTINCT user_id), 2)::numeric FROM (" + TOGETHER_EVIDENCE + ") ev"

ARRIVAL_EVIDENCE = {
    "created_same_address": """
        WITH ev AS (
            SELECT e.user_id, e.ip, min(j.joined_at) AS at
            FROM {login} e
            JOIN {joins} j ON j.user_id = e.user_id
            WHERE e.ip IS NOT NULL
              AND e.first_at <= j.joined_at + interval '1 hour'
              AND e.last_at >= j.joined_at - interval '5 minutes'
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
        WITH invites AS (""" + INVITES + """),
        crowd AS (
            SELECT actor_id, count(*) AS people FROM invites GROUP BY 1
        )
        SELECT least(i.actor_id, i.entity_id) AS a_user_id,
               greatest(i.actor_id, i.entity_id) AS b_user_id,
               i.actor_id AS value, c.people,
               %(weight)s::numeric * rarity(%(whole)s::numeric, (c.people + 1)::numeric) AS score,
               i.at AS first_seen, i.at AS last_seen
        FROM invites i
        JOIN crowd c ON c.actor_id = i.actor_id
        WHERE c.people <= %(ceiling)s {not_crowded_actor}
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
            SELECT e.user_id, u.ua, min(e.first_at) AS first_at
            FROM {login} e
            JOIN slack.user_agent u ON u.id = e.ua_id
            WHERE length(u.ua) >= {shortest}
            GROUP BY 1, 2
        ),
        crowd AS (
            SELECT ua, count(*) AS people FROM agent GROUP BY 1
            HAVING count(*) BETWEEN 2 AND %(ceiling)s {not_crowded_ua}
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

BURST = """
WITH ev AS (
    SELECT e.user_id,
           host(e.ip) || ' ' || to_char(e.hour, 'YYYY-MM-DD HH24')
               || ' ' || left(md5(u.ua), 12) AS value,
           min(e.first_at) AS seen
    FROM {login} e
    JOIN slack.user_agent u ON u.id = e.ua_id
    LEFT JOIN fd.ip_network n ON n.ip_prefix = e.ip_prefix
    WHERE e.ip IS NOT NULL
      AND (n.class IN ('rotating', 'vpn', 'hosting', 'tor')
           OR EXISTS (SELECT 1 FROM {shared_ip} s WHERE s.ip = e.ip))
    GROUP BY 1, 2
),
crowd AS (
    SELECT value, count(*) AS people FROM ev GROUP BY 1
),
keep AS (
    SELECT value, people FROM crowd WHERE people BETWEEN 2 AND %(ceiling)s
),
small AS (
    SELECT e.user_id, e.value, e.seen, j.joined_at
    FROM ev e
    JOIN keep k ON k.value = e.value
    JOIN {joins} j ON j.user_id = e.user_id
)
SELECT least(a.user_id, b.user_id) AS a_user_id,
       greatest(a.user_id, b.user_id) AS b_user_id,
       a.value, k.people, %(weight)s::numeric AS score,
       least(a.seen, b.seen) AS first_seen, greatest(a.seen, b.seen) AS last_seen
FROM small a
JOIN small b ON b.value = a.value AND b.user_id > a.user_id
            AND b.joined_at BETWEEN a.joined_at - make_interval(days => %(window)s)
                                AND a.joined_at + make_interval(days => %(window)s)
JOIN keep k ON k.value = a.value
"""

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
ORDER BY a_user_id, b_user_id, score DESC, value
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
    ORDER BY a_user_id, b_user_id, signal, score DESC, value
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
           (array_agg(family ORDER BY score DESC, family))[1] AS top_family,
           jsonb_object_agg(family, round(score::numeric, 3)) AS families,
           min(first_seen) AS first_seen,
           max(last_seen) AS last_seen
    FROM family
    GROUP BY a_user_id, b_user_id
    HAVING sum(score) >= %(floor)s AND bool_or(NOT corroborating)
),
named AS (
    SELECT b.a_user_id, b.b_user_id,
           (array_agg(b.signal ORDER BY b.score DESC, b.signal))[1] AS top_signal,
           jsonb_object_agg(b.signal, jsonb_build_object(
               'value', b.value, 'people', b.people, 'score', round(b.score::numeric, 3))) AS signals
    FROM best b
    JOIN pair p ON p.a_user_id = b.a_user_id AND p.b_user_id = b.b_user_id
    GROUP BY b.a_user_id, b.b_user_id
)
SELECT p.a_user_id, p.b_user_id, p.score, n.top_signal, p.top_family, p.families, n.signals,
       p.first_seen, p.last_seen, NULL::text AS label
FROM pair p
JOIN named n ON n.a_user_id = p.a_user_id AND n.b_user_id = p.b_user_id
"""

PASS_INDEX = "CREATE INDEX ON link_pass (a_user_id, b_user_id)"

PRESENCE = """
CREATE TEMP TABLE presence ON COMMIT DROP AS
SELECT DISTINCT s.user_id, s.hour, s.country
FROM {sighting} s
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
INSERT INTO fd.member_link
    (a_user_id, b_user_id, score, top_signal, top_family, families, signals, first_seen, last_seen,
     label, computed_at)
SELECT a_user_id, b_user_id, score, top_signal, top_family, families, signals, first_seen, last_seen,
       label, now()
FROM link_pass
ON CONFLICT (a_user_id, b_user_id) DO UPDATE SET
    score = EXCLUDED.score,
    top_signal = EXCLUDED.top_signal,
    top_family = EXCLUDED.top_family,
    families = EXCLUDED.families,
    signals = EXCLUDED.signals,
    first_seen = EXCLUDED.first_seen,
    last_seen = EXCLUDED.last_seen,
    label = EXCLUDED.label,
    computed_at = EXCLUDED.computed_at
WHERE (fd.member_link.score, fd.member_link.top_signal, fd.member_link.top_family,
       fd.member_link.families,
       fd.member_link.signals, fd.member_link.first_seen, fd.member_link.last_seen,
       fd.member_link.label)
      IS DISTINCT FROM (EXCLUDED.score, EXCLUDED.top_signal, EXCLUDED.top_family,
                        EXCLUDED.families,
                        EXCLUDED.signals, EXCLUDED.first_seen, EXCLUDED.last_seen, EXCLUDED.label)
"""

SWEEP = """
DELETE FROM fd.member_link l
WHERE l.computed_at < now()
  AND NOT EXISTS (SELECT 1 FROM link_pass p
                  WHERE p.a_user_id = l.a_user_id AND p.b_user_id = l.b_user_id)
"""


FULL = {
    "login": "fd.login_event",
    "identity": "fd.member_identity",
    "member": "fd.member",
    "joins": "fd.member_joins",
    "audit": "slack.audit_event",
    "shared_ip": "shared_ip",
    "sighting": "sighting",
    "crowded": None,
}


def catalogue():
    return yaml.safe_load(SIGNALS_FILE.read_text())


def scoring(held=None):
    return (held or catalogue())["scoring"]


def shared(held=None):
    return (held or catalogue()).get("shared_networks", {})


def sightings_of(held):
    return int(shared(held).get("min_sightings", 1))


def mark_shared(conn, held):
    settings = shared(held)
    conn.execute(SHARED_ISP, {"rotates": settings.get("rotates_above", 5.0),
                              "crowds": settings.get("crowds_above", 40)})
    conn.execute(SHARED_IP)
    conn.execute(SHARED_INDEX)
    conn.execute(KEEP_SHARED)
    row = conn.execute("SELECT count(*) FROM shared_ip").fetchone()
    return row[0] if row else 0


def families(held=None):
    return (held or catalogue())["families"]


def signals(held=None):
    held = held or catalogue()
    found = {name: {**one, "family": NETWORK} for name, one in held["network_signals"].items()}
    found.update({name: {**one, "family": DEVICE} for name, one in held["device_signals"].items()})
    found.update({name: {**one, "family": IDENTITY} for name, one in held["identity_signals"].items()})
    found.update({name: {**one, "family": NAME} for name, one in held["name_signals"].items()})
    found.update({name: {**one, "family": ARRIVAL} for name, one in held["arrival_signals"].items()})
    return found


def against(held=None):
    return (held or catalogue())["against"]


def labels(held=None):
    return (held or catalogue())["labels"]


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


def not_crowded(sources, column):
    if not sources.get("crowded"):
        return ""
    return f"AND {column} NOT IN (SELECT value FROM {sources['crowded']} WHERE signal = %(name)s)"


def names_for(sources, settings, sightings):
    return {**sources, "sightings": sightings, "shortest": SHORTEST_AGENT,
            "range_ceiling": settings.get("range_ceiling", 20), "shortest_local": SHORTEST_LOCAL,
            "shortest_name": SHORTEST_NAME, "longest_stem": SHORTEST_LONG_STEM,
            "not_crowded_value": not_crowded(sources, "value"),
            "not_crowded_ua": not_crowded(sources, "ua"),
            "not_crowded_actor": not_crowded(sources, "i.actor_id")}


def source_of(name):
    return (NETWORK_EVIDENCE.get(name) or DEVICE_EVIDENCE.get(name) or IDENTITY_EVIDENCE.get(name)
            or NAME_EVIDENCE.get(name) or EVIDENCE.get(name))


def evidence(name, settings, sightings, sources=FULL):
    names = names_for(sources, settings, sightings)
    args = {"weight": settings["weight"], "ceiling": settings.get("crowd_ceiling")}
    if name == IP_BURST:
        return BURST.format(**names), {**args, "window": settings["window_days"]}
    if name in ARRIVAL_EVIDENCE:
        return ARRIVAL_EVIDENCE[name].format(**names), {**args, "window": settings.get("window_seconds", 1800)}
    if name == JOINED_TOGETHER:
        return TOGETHER_SQL.format(**names), {**args, "window": settings.get("window_seconds", 300)}
    source = source_of(name)
    if source is None:
        return None, None
    return PAIRS_SQL.format(evidence=source.format(**names), **names), args


def whole_sql(name, settings, sightings, sources=FULL):
    names = names_for(sources, settings, sightings)
    if name == JOINED_TOGETHER:
        return TOGETHER_WHOLE.format(**names)
    if name == "invited_by":
        return INVITES_WHOLE.format(**names)
    if name in ARRIVAL_EVIDENCE or name == IP_BURST:
        return None
    source = source_of(name)
    return WHOLE_SQL.format(evidence=source.format(**names)) if source else None


def measure(conn, held, sources=FULL):
    sightings = sightings_of(held)
    found = {}
    for name, settings in signals(held).items():
        sql = whole_sql(name, settings, sightings, sources)
        if sql:
            found[name] = conn.execute(sql).fetchone()[0]
    return found


def keep_wholes(conn, wholes):
    names = sorted(wholes)
    conn.execute(KEEP_WHOLE, (names, [wholes[name] for name in names]))


def held_wholes(conn):
    return dict(conn.execute(HELD_WHOLE).fetchall())


def wanting(held, wholes):
    sightings = sightings_of(held)
    return sorted(name for name, settings in signals(held).items()
                  if whole_sql(name, settings, sightings) and name not in wholes)


def mailbox_rows(identities, staff):
    for user_id, email in identities:
        box = mailbox(email)
        if box is None:
            continue
        local, _, domain = box.rpartition("@")
        if staff_domain(domain, staff):
            continue
        yield user_id, box, local, domain


def load_mailboxes(conn, held, sources=FULL):
    conn.execute(MAILBOX)
    staff = held.get("staff_domains", [])
    identities = conn.execute(IDENTITIES_SQL.format(**sources)).fetchall()
    with conn.cursor() as cur, cur.copy("COPY mailbox (user_id, box, local, domain) FROM STDIN") as copy:
        for row in mailbox_rows(identities, staff):
            copy.write_row(row)
    conn.execute(STAFF)
    with conn.cursor() as cur, cur.copy("COPY staff_member (user_id) FROM STDIN") as copy:
        for row in staff_members(identities, staff):
            copy.write_row(row)


def prepare(conn, held, sources=FULL):
    conn.execute(RARITY)
    conn.execute(STAGE)
    conn.execute(SIGHTING.format(**sources))
    conn.execute("ANALYZE sighting")
    load_mailboxes(conn, held, sources)
    conn.execute("ANALYZE mailbox")
    conn.execute("ANALYZE staff_member")


def gather(conn, held, wholes, sources=FULL):
    sightings = sightings_of(held)
    counted = {}

    for name, settings in signals(held).items():
        pairs, args = evidence(name, settings, sightings, sources)
        if pairs is None:
            continue
        if name in wholes:
            args["whole"] = wholes[name]
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


def settle(conn, held, sources=FULL, sweep=SWEEP, lap=lambda _step: None):
    marks = scoring(held)
    named = labels(held)
    labelled = {}
    with conn.cursor() as cur:
        cur.execute(PASS, {**family_table(held), "floor": marks["floor"]})
        cur.execute(PASS_INDEX)
        cur.execute("ANALYZE link_pass")
        lap("score")
        cur.execute(PRESENCE.format(**sources))
        cur.execute(PRESENCE_INDEX)
        cur.execute("ANALYZE presence")
        cur.execute(AGAINST, {"weight": against(held)[TWO_COUNTRIES]["weight"]})
        countered = cur.rowcount
        lap("countries")
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
        cur.execute(sweep)
        gone = cur.rowcount
        cur.execute("SELECT count(*) FROM link_pass")
        kept = cur.fetchone()[0]
    return kept, changed, gone, countered, labelled


def run(conn):
    held = catalogue()

    took = {}
    clock = time.monotonic()

    def lap(step):
        nonlocal clock
        now = time.monotonic()
        took[step] = now - clock
        clock = now

    with ingest_run(conn, SOURCE) as counts:
        conn.execute(QUIET)
        put_aside = mark_shared(conn, held)
        conn.execute("ANALYZE shared_ip")
        prepare(conn, held)
        wholes = measure(conn, held)
        keep_wholes(conn, wholes)
        found = gather(conn, held, wholes)
        conn.execute("ANALYZE link_part")
        lap("gather")
        kept, changed, gone, countered, labelled = settle(conn, held, lap=lap)
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
