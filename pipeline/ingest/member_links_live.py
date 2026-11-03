import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime

from ingest import member_links as links
from lib import sources
from lib.db import ingest_run, record_steps

SOURCE = "member_links_live"
RECENT_JOIN_DAYS = 7
CAP = 101
FIRST_BATCH = 50
SMALLEST_BATCH = 10
LARGEST_BATCH = 300
BUDGET_SHARE = 0.75

TOUCHED_SQL = "SELECT user_id, touched_at FROM fd.member_touch ORDER BY touched_at LIMIT %s"

RECENT_JOINS_SQL = """
SELECT t.user_id, t.touched_at
FROM fd.member_touch t
JOIN fd.member_joins j ON j.user_id = t.user_id
WHERE j.joined_at > now() - make_interval(days => %s)
ORDER BY t.touched_at
LIMIT %s
"""

QUEUED_SQL = "SELECT user_id, touched_at FROM fd.member_touch WHERE user_id = ANY(%s)"

DONE_SQL = """
DELETE FROM fd.member_touch t
USING unnest(%s::text[], %s::timestamptz[]) AS done (user_id, touched_at)
WHERE t.user_id = done.user_id AND t.touched_at = done.touched_at
"""

TOUCHED = """
CREATE TEMP TABLE touched ON COMMIT DROP AS
SELECT DISTINCT user_id FROM unnest(%(touched)s::text[]) AS user_id
"""

TRAIT_USER_COUNT = """
SELECT count(*) FROM (
    SELECT 1 FROM fd.member_trait h WHERE h.kind = v.kind AND h.value = v.value LIMIT %(cap)s + 1
) capped
"""

SESSION_USER_COUNT = """
SELECT count(*) FROM (
    SELECT DISTINCT h.user_id
    FROM slack.user_agent a
    JOIN fd.member_trait h ON h.kind = 'ua_id' AND h.value = a.id::text
    WHERE a.app = s.app AND a.os = s.os
    LIMIT %(cap)s + 1
) capped
"""

BUCKET = """
SELECT j2.user_id FROM fd.member_joins j1
JOIN fd.member_joins j2
  ON j2.joined_at >= date_trunc('hour', j1.joined_at)
 AND j2.joined_at < date_trunc('hour', j1.joined_at) + interval '1 hour'
WHERE j1.user_id IN (SELECT user_id FROM {members}) AND j1.joined_at IS NOT NULL
"""

RESCORED = """
CREATE TEMP TABLE rescored ON COMMIT DROP AS
SELECT user_id FROM touched
"""

SCOPE_VALUE = f"""
CREATE TEMP TABLE scope_value ON COMMIT DROP AS
SELECT v.kind, v.value, ({TRAIT_USER_COUNT}) AS user_count
FROM (SELECT DISTINCT kind, value FROM fd.member_trait
      WHERE user_id IN (SELECT user_id FROM rescored) AND kind NOT IN ('ip', 'ip_prefix')
      UNION
      SELECT 'inviter', user_id FROM rescored) v
"""

SCOPE_SESSION = f"""
CREATE TEMP TABLE scope_session ON COMMIT DROP AS
SELECT s.app, s.os, ({SESSION_USER_COUNT}) AS user_count
FROM (SELECT DISTINCT a.app, a.os FROM slack.user_agent a
      WHERE a.app IS NOT NULL AND a.os IS NOT NULL
        AND a.id IN (SELECT CASE WHEN value ~ '^[0-9]{1,18}$' THEN value::bigint END
                     FROM scope_value WHERE kind = 'ua_id')) s
"""

ANONYMIZED = "('rotating', 'vpn', 'hosting', 'tor')"

SCOPE_PREFIX = f"""
CREATE TEMP TABLE scope_prefix ON COMMIT DROP AS
SELECT observed.ip_prefix
FROM (SELECT DISTINCT network(set_masklen(value::inet,
                      CASE WHEN family(value::inet) = 4 THEN 24 ELSE 64 END)) AS ip_prefix
      FROM fd.member_trait
      WHERE kind = 'ip_prefix' AND user_id IN (SELECT user_id FROM rescored)) observed
LEFT JOIN fd.ip_network n ON n.ip_prefix = observed.ip_prefix
WHERE n.class IS NULL OR n.class NOT IN {ANONYMIZED}
"""

SCOPE_EXIT = f"""
CREATE TEMP TABLE scope_exit ON COMMIT DROP AS
SELECT DISTINCT e.ip
FROM fd.login_event e
JOIN fd.ip_network n ON n.ip_prefix = e.ip_prefix AND n.class IN {ANONYMIZED}
WHERE e.user_id IN (SELECT user_id FROM rescored) AND e.ip IS NOT NULL
"""

SCOPE_AGENT = """
CREATE TEMP TABLE scope_agent ON COMMIT DROP AS
SELECT a.id AS ua_id
FROM (SELECT CASE WHEN value ~ '^[0-9]{1,18}$' THEN value::bigint END AS id
      FROM scope_value WHERE kind = 'ua_id' AND user_count <= %(cap)s) v
JOIN slack.user_agent a ON a.id = v.id
UNION
SELECT a.id FROM scope_session s
JOIN slack.user_agent a ON a.app = s.app AND a.os = s.os
WHERE s.user_count <= %(cap)s
"""

DEVICE_USER = """
CREATE TEMP TABLE device_user ON COMMIT DROP AS
SELECT DISTINCT h.user_id FROM scope_agent a
JOIN fd.member_trait h ON h.kind = 'ua_id' AND h.value = a.ua_id::text
"""

SCOPE_LOGIN = """
CREATE TEMP TABLE scope_login ON COMMIT DROP AS
SELECT e.* FROM fd.login_event e
WHERE e.ip_prefix IN (SELECT ip_prefix FROM scope_prefix)
UNION ALL
SELECT e.* FROM fd.login_event e
WHERE e.ip IN (SELECT ip FROM scope_exit)
UNION ALL
SELECT e.* FROM fd.login_event e
WHERE e.user_id IN (SELECT user_id FROM device_user)
  AND e.ua_id IN (SELECT ua_id FROM scope_agent)
  AND (e.ip_prefix IS NULL OR e.ip_prefix NOT IN (SELECT ip_prefix FROM scope_prefix))
  AND (e.ip IS NULL OR e.ip NOT IN (SELECT ip FROM scope_exit))
"""

SCOPE_USER = f"""
CREATE TEMP TABLE scope_user ON COMMIT DROP AS
SELECT user_id FROM rescored
UNION
SELECT h.user_id FROM scope_value v
JOIN fd.member_trait h ON h.kind = v.kind AND h.value = v.value
WHERE v.user_count <= %(cap)s
UNION
SELECT user_id FROM device_user
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

OVER_CAP = """
CREATE TEMP TABLE over_cap ON COMMIT DROP AS
SELECT signal, value FROM (
    SELECT signals.signal, CASE WHEN v.kind = 'ua_id' THEN a.ua ELSE v.value END AS value
    FROM scope_value v
    JOIN (VALUES ('email_domain', 'email_domain'), ('mailbox', 'mailbox_alias'), ('local_part', 'local_part'),
                 ('full_name', 'full_name'), ('display_name', 'display_name'),
                 ('handle_stem', 'handle_stem'), ('handle_stem', 'handle_stem_long'),
                 ('ua_id', 'device_agent'), ('ua_id', 'after_ban_device'), ('ja4', 'device_ja4'), ('ja3', 'device_ja3'),
                 ('inviter', 'invited_by')) AS signals (kind, signal)
      ON signals.kind = v.kind
    LEFT JOIN slack.user_agent a ON v.kind = 'ua_id'
      AND a.id = CASE WHEN v.kind = 'ua_id' AND v.value ~ '^[0-9]{1,18}$' THEN v.value::bigint END
    WHERE v.user_count > %(cap)s
    UNION ALL
    SELECT 'session_agent', app || ' / ' || os FROM scope_session WHERE user_count > %(cap)s
) over_cap_value
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
    "over_cap": "over_cap",
}

MEASURE_SOURCES = {**links.FULL, "shared_ip": "fd.shared_ip"}

SCOPE = (TOUCHED, RESCORED, SCOPE_VALUE, SCOPE_SESSION, SCOPE_PREFIX, SCOPE_EXIT,
         SCOPE_AGENT, DEVICE_USER, SCOPE_LOGIN, SCOPE_USER, *SCOPE_TABLES, OVER_CAP)


def scope(conn, touched):
    args = {"touched": touched, "cap": CAP}
    for sql in SCOPE:
        conn.execute(sql, args)
        conn.execute(f"ANALYZE {sql.split('CREATE TEMP TABLE ', 1)[1].split()[0]}")
    return conn.execute("SELECT count(*) FROM rescored").fetchone()[0]


def reads_table(names, table):
    return any(f"FROM {table}" in (links.source_of(name) or "") for name in names)


def ensure_wholes(conn, catalogue, wholes):
    missing = links.missing_wholes(catalogue, wholes)
    if not missing:
        return wholes
    if reads_table(missing, "sighting"):
        conn.execute(links.SIGHTING.format(**MEASURE_SOURCES))
    if reads_table(missing, "mailbox"):
        links.load_mailboxes(conn, catalogue, MEASURE_SOURCES)
    measured_wholes = links.measure(conn, catalogue, MEASURE_SOURCES, missing)
    links.save_wholes(conn, measured_wholes)
    conn.commit()
    print(f"{SOURCE}: measured {', '.join(sorted(measured_wholes))} without a full rebuild")
    return {**wholes, **measured_wholes}


@dataclass
class BatchSizer:
    seconds_per_member: float | None = None
    last_batch: int = FIRST_BATCH

    def batch(self, budget_seconds):
        if not self.seconds_per_member:
            return FIRST_BATCH
        fitted = int(budget_seconds * BUDGET_SHARE / self.seconds_per_member)
        return max(SMALLEST_BATCH, min(LARGEST_BATCH, 2 * self.last_batch, fitted))

    def record(self, batch, members, seconds):
        self.last_batch = batch
        self.seconds_per_member = seconds / max(members, 1)


BATCH_SIZER = BatchSizer()


@contextmanager
def timed_step(steps, name):
    started = datetime.now(UTC)
    yield
    steps.append((f"{SOURCE}:{name}", started, datetime.now(UTC)))


def rescore(conn, catalogue, wholes, touched, steps=None):
    steps = [] if steps is None else steps
    with timed_step(steps, "scope"):
        rescored_count = scope(conn, touched)
    with timed_step(steps, "prepare"):
        links.prepare(conn, catalogue, LIVE)
    with timed_step(steps, "gather"):
        signal_counts = links.load_signal_pairs(conn, catalogue, wholes, LIVE)
        conn.execute(ONLY_RESCORED)
        conn.execute("ANALYZE link_part")
    with timed_step(steps, "settle"):
        retained, changed, removed, _country_conflict_count, _label_counts = links.score_pairs(conn, catalogue, LIVE, SWEEP)
    return rescored_count, retained, changed, removed, signal_counts


def score(conn, user_ids):
    catalogue = links.catalogue()
    wholes = links.load_wholes(conn)
    if links.missing_wholes(catalogue, wholes):
        return None
    queued = conn.execute(QUEUED_SQL, (list(user_ids),)).fetchall()
    _rescored_count, _retained, changed, _removed, _signal_counts = rescore(conn, catalogue, wholes, list(user_ids))
    if queued:
        conn.execute(DONE_SQL, ([user_id for user_id, _ in queued], [at for _, at in queued]))
    conn.commit()
    return changed


def next_batch(conn, batch):
    recent = conn.execute(RECENT_JOINS_SQL, (RECENT_JOIN_DAYS, batch)).fetchall()
    return recent or conn.execute(TOUCHED_SQL, (batch,)).fetchall()


def run(conn, sizer=BATCH_SIZER):
    catalogue = links.catalogue()
    wholes = ensure_wholes(conn, catalogue, links.load_wholes(conn))
    batch = sizer.batch(sources.unit_budget_seconds(SOURCE))
    queued = next_batch(conn, batch)
    conn.commit()
    if not queued:
        return 0

    started = time.monotonic()
    touched = [user_id for user_id, _ in queued]
    steps = []
    with ingest_run(conn, SOURCE) as counts:
        rescored_count, retained, changed, removed, _signal_counts = rescore(conn, catalogue, wholes, touched, steps)
        conn.execute(DONE_SQL, (touched, [at for _, at in queued]))
        record_steps(conn, counts.run_id, steps)
        conn.commit()
        counts.rows_in = changed

    seconds = time.monotonic() - started
    sizer.record(batch, len(touched), seconds)
    print(f"{SOURCE}: {len(touched)} touched of a batch of {batch}, {rescored_count} rescored, {retained} link(s) kept, "
          f"{changed} written, {removed} dropped in {seconds:.2f}s ("
          + ", ".join(f"{source.split(':')[1]} {(finished - begun).total_seconds():.1f}s" for source, begun, finished in steps)
          + ")")
    return len(touched)
