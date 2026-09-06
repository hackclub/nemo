from collections import defaultdict

from lib import settings, sources

SUBJECT = "breaker"
MODES = ("observe", "on", "off")
SOURCE_TRIP = 3
CREDENTIAL_TRIP = 3
PROXY_TRIP = 2
LOOKBACK_DAYS = 14

RUNS_SQL = """
WITH ranked AS (
    SELECT source_key, status, error_class, had_fault_body,
           row_number() OVER (PARTITION BY source_key ORDER BY started_at DESC) AS n
    FROM   raw.ingest_run
    WHERE  parent_run_id IS NOT NULL AND source_key IS NOT NULL
      AND  status IN ('ok', 'partial', 'failed')
      AND  started_at > now() - make_interval(days => %s)
)
SELECT source_key, status, error_class, had_fault_body
FROM   ranked WHERE n <= %s
ORDER  BY source_key, n
"""

PROXY_SQL = "SELECT note FROM raw.worker_heartbeat WHERE worker = 'proxy'"

ACKS_SQL = """
SELECT source_key FROM ingest.incident_ack
WHERE  kind = 'breaker' AND muted_until IS NOT NULL AND muted_until > now()
"""

RECORD_SQL = """
INSERT INTO ingest.quality_result (run_id, subject, assertion, severity, status, observed, expected)
VALUES (%s, 'breaker', %s, %s, %s, %s, %s)
"""


def mode(conn):
    said = str(settings.said(conn, settings.ENGINE, "breaker_mode", "observe")).strip().lower()
    return said if said in MODES else "observe"


def streak_of(rows):
    streak, edge = 0, False
    for status, error_class, had_fault_body in rows:
        if status != "failed" or error_class != "transport":
            break
        streak += 1
        if not had_fault_body:
            edge = True
    return streak, edge


def credential_of(key):
    try:
        return sources.source(key).get("credential")
    except sources.Unknown:
        return None


def open_scopes(streaks, proxy_down=False):
    scopes = {}
    for key, (streak, _) in streaks.items():
        if streak >= SOURCE_TRIP:
            scopes[("source", key)] = (streak, SOURCE_TRIP, f"{streak} consecutive transport failures")
    by_credential = defaultdict(list)
    edge_credentials = set()
    for key, (streak, edge) in streaks.items():
        credential = credential_of(key)
        if streak and credential and credential != "none":
            by_credential[credential].append(key)
            if edge:
                edge_credentials.add(credential)
    for credential, keys in by_credential.items():
        if len(keys) >= CREDENTIAL_TRIP:
            scopes[("credential", credential)] = (
                len(keys), CREDENTIAL_TRIP, f"{len(keys)} sources failing on transport: {', '.join(sorted(keys))}")
    if proxy_down:
        scopes[("proxy", "proxy")] = (1, 1, "proxy heartbeat reports FAILED")
    elif len(edge_credentials) >= PROXY_TRIP:
        scopes[("proxy", "proxy")] = (
            len(edge_credentials), PROXY_TRIP,
            f"edge answers without a proxy body on {len(edge_credentials)} credentials")
    return scopes


def streaks(conn, depth=10):
    per_source = defaultdict(list)
    with conn.cursor() as cur:
        cur.execute(RUNS_SQL, (LOOKBACK_DAYS, depth))
        for key, status, error_class, had_fault_body in cur.fetchall():
            per_source[key].append((status, error_class, had_fault_body))
    return {key: streak_of(rows) for key, rows in per_source.items()}


def proxy_down(conn):
    with conn.cursor() as cur:
        cur.execute(PROXY_SQL)
        row = cur.fetchone()
    return bool(row and str(row[0] or "").startswith("FAILED"))


def acked(conn):
    with conn.cursor() as cur:
        cur.execute(ACKS_SQL)
        return {row[0] for row in cur.fetchall()}


def evaluate(conn):
    scopes = open_scopes(streaks(conn), proxy_down(conn))
    overrides = acked(conn)
    return [
        {"scope": scope, "key": key, "streak": streak, "threshold": threshold,
         "detail": detail, "overridden": key in overrides}
        for (scope, key), (streak, threshold, detail) in sorted(scopes.items())
    ]


def covering(verdicts, source_key):
    credential = credential_of(source_key)
    for verdict in verdicts:
        if verdict["overridden"]:
            continue
        if verdict["scope"] == "proxy":
            return verdict
        if verdict["scope"] == "credential" and verdict["key"] == credential:
            return verdict
        if verdict["scope"] == "source" and verdict["key"] == source_key:
            return verdict
    return None


def blocked(conn, source_key):
    if mode(conn) != "on":
        return None
    verdict = covering(evaluate(conn), source_key)
    if verdict is None:
        return None
    return f"breaker open on {verdict['scope']} {verdict['key']}: {verdict['detail']}"


def record(conn, run_id=None):
    verdicts = evaluate(conn)
    current = mode(conn)
    severity = "error" if current == "on" else "warn"
    with conn.cursor() as cur:
        if not verdicts:
            cur.execute(RECORD_SQL, (run_id, f"mode:{current}", "info", "pass", 0, 0))
        for verdict in verdicts:
            status = "pass" if verdict["overridden"] else "fail"
            cur.execute(RECORD_SQL, (
                run_id, f"{verdict['scope']}:{verdict['key']}", severity if status == "fail" else "info",
                status, verdict["streak"], verdict["threshold"] - 1))
    conn.commit()
    return verdicts
