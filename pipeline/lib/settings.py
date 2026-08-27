from datetime import timedelta

from lib import sources

TUNED_SQL = "SELECT source, name, value FROM app.engine_setting"

LAST_OK_SQL = """
SELECT max(finished_at)
FROM raw.ingest_run
WHERE status = 'ok' AND source = ANY(%s)
"""

ENGINE = "engine"
DEFAULTS = {"run_at": "03:00", "budget_minutes": "45"}

PERIOD = {
    "daily": timedelta(hours=20),
    "weekly": timedelta(days=7),
    "monthly": timedelta(days=28),
}


def tuned(conn):
    try:
        with conn.cursor() as cur:
            cur.execute(TUNED_SQL)
            return {(source, name): value for source, name, value in cur.fetchall()}
    except Exception:
        conn.rollback()
        return {}


def said(conn, source, name, fallback):
    return tuned(conn).get((source, name), fallback)


def cadence(conn, key):
    return said(conn, key, "cadence", sources.says(key, "cadence"))


def enabled(conn, key):
    return said(conn, key, "enabled", "true") != "false"


def limit(conn, key, name):
    bounds = sources.limit(key, name)
    return sources.clamped(key, name, said(conn, key, name, bounds["default"]))


def run_at(conn):
    return said(conn, ENGINE, "run_at", DEFAULTS["run_at"])


def budget_minutes(conn):
    return int(said(conn, ENGINE, "budget_minutes", DEFAULTS["budget_minutes"]))


KEEP = "keep"


def floor_days(key):
    floor = sources.prune_floor(key)
    if not floor:
        return None
    count, unit = floor.split()
    return int(count) * (30 if unit.startswith("month") else 1)


def retention_days(conn, key):
    asked = said(conn, key, "retention_days", KEEP)
    if asked == KEEP:
        return None

    floor = floor_days(key)
    days = int(asked)
    if floor and days < floor:
        raise ValueError(f"{key}: {days} days is under the {floor} day floor")
    return days


def last_ok(conn, key):
    with conn.cursor() as cur:
        cur.execute(LAST_OK_SQL, (list(sources.runs_as(key)),))
        return cur.fetchone()[0]


def skip_reason(conn, key, now):
    if not enabled(conn, key):
        return "paused"

    how_often = cadence(conn, key)
    if how_often not in PERIOD:
        return f"{how_often}, not scheduled"

    since = last_ok(conn, key)
    if since is None:
        return None

    due_at = since + PERIOD[how_often]
    if now < due_at:
        return f"{how_often}, next due {due_at:%b %-d %H:%M}"

    return None
