import time

from ingest import member_links as links
from lib.db import ingest_run

SOURCE = "member_links_live"
BATCH = 300
CAP = 101

TOUCHED_SQL = "SELECT user_id, touched_at FROM fd.member_touch ORDER BY touched_at LIMIT %s"

DONE_SQL = """
DELETE FROM fd.member_touch t
USING unnest(%s::text[], %s::timestamptz[]) AS done (user_id, touched_at)
WHERE t.user_id = done.user_id AND t.touched_at = done.touched_at
"""

TOUCHED = """
CREATE TEMP TABLE touched ON COMMIT DROP AS
SELECT DISTINCT user_id FROM unnest(%(touched)s::text[]) AS user_id
"""

HOLDERS = """
SELECT count(*) FROM (
    SELECT 1 FROM fd.member_trait h WHERE h.kind = v.kind AND h.value = v.value LIMIT %(cap)s + 1
) held
"""

SESSION_HOLDERS = """
SELECT count(*) FROM (
    SELECT DISTINCT h.user_id
    FROM slack.user_agent a
    JOIN fd.member_trait h ON h.kind = 'ua_id' AND h.value = a.id::text
    WHERE a.app = s.app AND a.os = s.os
    LIMIT %(cap)s + 1
) held
"""

BUCKET = """
SELECT j2.user_id FROM fd.member_joins j1
JOIN fd.member_joins j2
  ON j2.joined_at >= date_trunc('hour', j1.joined_at)
 AND j2.joined_at < date_trunc('hour', j1.joined_at) + interval '1 hour'
WHERE j1.user_id IN (SELECT user_id FROM {members}) AND j1.joined_at IS NOT NULL
"""

TOUCHED_VALUE = f"""
CREATE TEMP TABLE touched_value ON COMMIT DROP AS
SELECT v.kind, v.value, ({HOLDERS}) AS people
FROM (SELECT DISTINCT kind, value FROM fd.member_trait
      WHERE user_id IN (SELECT user_id FROM touched)
      UNION
      SELECT 'inviter', user_id FROM touched) v
"""

TOUCHED_SESSION = f"""
CREATE TEMP TABLE touched_session ON COMMIT DROP AS
SELECT s.app, s.os, ({SESSION_HOLDERS}) AS people
FROM (SELECT DISTINCT a.app, a.os FROM slack.user_agent a
      WHERE a.app IS NOT NULL AND a.os IS NOT NULL
        AND a.id::text IN (SELECT value FROM touched_value WHERE kind = 'ua_id')) s
"""

RESCORED = f"""
CREATE TEMP TABLE rescored ON COMMIT DROP AS
SELECT user_id FROM touched
UNION
SELECT h.user_id FROM touched_value v
JOIN fd.member_trait h ON h.kind = v.kind AND h.value = v.value
WHERE v.people <= %(cap)s
UNION
SELECT value FROM touched_value WHERE kind = 'inviter' AND value NOT IN (SELECT user_id FROM touched)
UNION
SELECT h.user_id FROM touched_session s
JOIN slack.user_agent a ON a.app = s.app AND a.os = s.os
JOIN fd.member_trait h ON h.kind = 'ua_id' AND h.value = a.id::text
WHERE s.people <= %(cap)s
UNION
SELECT user_id FROM ({BUCKET.format(members="touched")}) bucket
"""

SCOPE_VALUE = f"""
CREATE TEMP TABLE scope_value ON COMMIT DROP AS
SELECT v.kind, v.value, ({HOLDERS}) AS people
FROM (SELECT DISTINCT kind, value FROM fd.member_trait
      WHERE user_id IN (SELECT user_id FROM rescored) AND kind NOT IN ('ip', 'ip_prefix')
      UNION
      SELECT 'inviter', user_id FROM rescored) v
"""

SCOPE_SESSION = f"""
CREATE TEMP TABLE scope_session ON COMMIT DROP AS
SELECT s.app, s.os, ({SESSION_HOLDERS}) AS people
FROM (SELECT DISTINCT a.app, a.os FROM slack.user_agent a
      WHERE a.app IS NOT NULL AND a.os IS NOT NULL
        AND a.id::text IN (SELECT value FROM scope_value WHERE kind = 'ua_id')) s
"""

SCOPE_PREFIX = """
CREATE TEMP TABLE scope_prefix ON COMMIT DROP AS
SELECT DISTINCT network(set_masklen(value::inet,
                CASE WHEN family(value::inet) = 4 THEN 24 ELSE 64 END)) AS ip_prefix
FROM fd.member_trait
WHERE kind = 'ip_prefix' AND user_id IN (SELECT user_id FROM rescored)
"""

SCOPE_AGENT = """
CREATE TEMP TABLE scope_agent ON COMMIT DROP AS
SELECT a.id AS ua_id FROM scope_value v
JOIN slack.user_agent a ON a.id::text = v.value
WHERE v.kind = 'ua_id' AND v.people <= %(cap)s
UNION
SELECT a.id FROM scope_session s
JOIN slack.user_agent a ON a.app = s.app AND a.os = s.os
WHERE s.people <= %(cap)s
"""

DEVICE_HOLDER = """
CREATE TEMP TABLE device_holder ON COMMIT DROP AS
SELECT DISTINCT h.user_id FROM scope_agent a
JOIN fd.member_trait h ON h.kind = 'ua_id' AND h.value = a.ua_id::text
"""

SCOPE_LOGIN = """
CREATE TEMP TABLE scope_login ON COMMIT DROP AS
SELECT e.* FROM fd.login_event e
WHERE e.ip_prefix IN (SELECT ip_prefix FROM scope_prefix)
UNION ALL
SELECT e.* FROM fd.login_event e
WHERE e.user_id IN (SELECT user_id FROM device_holder)
  AND e.ua_id IN (SELECT ua_id FROM scope_agent)
  AND (e.ip_prefix IS NULL OR e.ip_prefix NOT IN (SELECT ip_prefix FROM scope_prefix))
"""

SCOPE_USER = f"""
CREATE TEMP TABLE scope_user ON COMMIT DROP AS
SELECT user_id FROM rescored
UNION
SELECT h.user_id FROM scope_value v
JOIN fd.member_trait h ON h.kind = v.kind AND h.value = v.value
WHERE v.people <= %(cap)s
UNION
SELECT user_id FROM device_holder
UNION
SELECT DISTINCT user_id FROM scope_login
UNION
SELECT value FROM scope_value WHERE kind = 'inviter'
UNION
SELECT user_id FROM ({BUCKET.format(members="rescored")}) bucket
"""

SCOPE_TABLES = (
    """
    CREATE TEMP TABLE scope_identity ON COMMIT DROP AS
    SELECT * FROM fd.member_identity WHERE user_id IN (SELECT user_id FROM scope_user)
    """,
    """
    CREATE TEMP TABLE scope_member ON COMMIT DROP AS
    SELECT * FROM fd.member WHERE user_id IN (SELECT user_id FROM scope_user)
    """,
    """
    CREATE TEMP TABLE scope_joins ON COMMIT DROP AS
    SELECT * FROM fd.member_joins WHERE user_id IN (SELECT user_id FROM scope_user)
    """,
    """
    CREATE TEMP TABLE scope_audit ON COMMIT DROP AS
    SELECT at, action, actor_id, entity_id, payload FROM slack.audit_event
    WHERE (action = 'anomaly' AND actor_id IN (SELECT user_id FROM scope_user))
       OR (action = 'user_created' AND (actor_id IN (SELECT user_id FROM scope_user)
                                        OR entity_id IN (SELECT user_id FROM scope_user)))
       OR (action IN ('user_deactivated', 'user_reactivated')
           AND entity_id IN (SELECT user_id FROM scope_user))
    """,
)

CROWDED = """
CREATE TEMP TABLE crowded ON COMMIT DROP AS
SELECT signal, value FROM (
    SELECT signals.signal, CASE WHEN v.kind = 'ua_id' THEN a.ua ELSE v.value END AS value
    FROM scope_value v
    JOIN (VALUES ('email_domain', 'email_domain'), ('mailbox', 'mailbox_alias'), ('local_part', 'local_part'),
                 ('full_name', 'full_name'), ('display_name', 'display_name'),
                 ('handle_stem', 'handle_stem'), ('handle_stem', 'handle_stem_long'),
                 ('ua_id', 'device_agent'), ('ua_id', 'after_ban_device'), ('ja4', 'device_ja4'),
                 ('inviter', 'invited_by')) AS signals (kind, signal)
      ON signals.kind = v.kind
    LEFT JOIN slack.user_agent a ON v.kind = 'ua_id' AND a.id::text = v.value
    WHERE v.people > %(cap)s
    UNION ALL
    SELECT 'session_agent', app || ' / ' || os FROM scope_session WHERE people > %(cap)s
) crowd
WHERE value IS NOT NULL
"""

ONLY_RESCORED = """
DELETE FROM link_part
WHERE a_user_id NOT IN (SELECT user_id FROM rescored)
  AND b_user_id NOT IN (SELECT user_id FROM rescored)
"""

SWEEP = """
DELETE FROM fd.member_link l
WHERE (l.a_user_id IN (SELECT user_id FROM rescored) OR l.b_user_id IN (SELECT user_id FROM rescored))
  AND NOT EXISTS (SELECT 1 FROM link_pass p
                  WHERE p.a_user_id = l.a_user_id AND p.b_user_id = l.b_user_id)
"""

PAIRED = "(SELECT * FROM fd.login_event WHERE user_id IN (SELECT a_user_id FROM link_pass UNION SELECT b_user_id FROM link_pass))"

LIVE = {
    "login": "scope_login",
    "identity": "scope_identity",
    "member": "scope_member",
    "joins": "scope_joins",
    "audit": "scope_audit",
    "shared_ip": "fd.shared_ip",
    "sighting": "(" + links.SIGHTING_SELECT.format(login=PAIRED, shared_ip="fd.shared_ip") + ")",
    "crowded": "crowded",
}

SCOPE = (TOUCHED, TOUCHED_VALUE, TOUCHED_SESSION, RESCORED, SCOPE_VALUE, SCOPE_SESSION, SCOPE_PREFIX,
         SCOPE_AGENT, DEVICE_HOLDER, SCOPE_LOGIN, SCOPE_USER, *SCOPE_TABLES, CROWDED)


def scope(conn, touched):
    args = {"touched": touched, "cap": CAP}
    for sql in SCOPE:
        conn.execute(sql, args)
    for table in ("rescored", "scope_login", "scope_user", "crowded"):
        conn.execute(f"ANALYZE {table}")
    return conn.execute("SELECT count(*) FROM rescored").fetchone()[0]


def rescore(conn, held, wholes, touched):
    widened = scope(conn, touched)
    links.prepare(conn, held, LIVE)
    found = links.gather(conn, held, wholes, LIVE)
    conn.execute(ONLY_RESCORED)
    conn.execute("ANALYZE link_part")
    kept, changed, gone, _countered, _labelled = links.settle(conn, held, LIVE, SWEEP)
    return widened, kept, changed, gone, found


def run(conn, batch=BATCH):
    held = links.catalogue()
    wholes = links.held_wholes(conn)
    missing = links.wanting(held, wholes)
    if missing:
        print(f"{SOURCE}: waiting for a full rebuild to measure {', '.join(missing)}")
        return 0
    queued = conn.execute(TOUCHED_SQL, (batch,)).fetchall()
    conn.commit()
    if not queued:
        return 0

    started = time.monotonic()
    touched = [user_id for user_id, _ in queued]
    with ingest_run(conn, SOURCE) as counts:
        widened, kept, changed, gone, _found = rescore(conn, held, wholes, touched)
        conn.execute(DONE_SQL, (touched, [at for _, at in queued]))
        conn.commit()
        counts.rows_in = changed

    print(f"{SOURCE}: {len(touched)} touched, {widened} rescored, {kept} link(s) kept, "
          f"{changed} written, {gone} dropped in {time.monotonic() - started:.2f}s")
    return len(touched)
