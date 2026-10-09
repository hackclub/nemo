from datetime import UTC, datetime, timedelta

from lib import member_seen, useragent
from lib.db import dead_letter, get_cursor, ingest_run, save_cursor
from lib.proxy_client import ProxyClient

SOURCE = "access_logs"
BACKFILL = "access_logs_backfill"
METHOD = "team.accessLogs"
CREDENTIAL = "admin"
PAGE = 1000
LAP_SECONDS = 120
MOST_PAGES = 20
BACKFILL_COMPLETE = "complete"
BACKFILL_MARKER_MAX_AGE_HOURS = 24 * 365

NEWEST_SQL = """
SELECT at FROM fd.login_event WHERE source = 'access_logs' ORDER BY at DESC LIMIT 1
"""

OLDEST_SQL = """
SELECT min(at) FROM fd.login_event WHERE source = 'access_logs'
"""

ROW_SQL = """
INSERT INTO fd.login_event
    (user_id, at, source, action, ip, ua, ua_app, ua_os,
     country, region, isp, seen, first_seen_at, ua_read_at)
VALUES (%s, %s, 'access_logs', 'access_log', %s, %s, %s, %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (user_id, at, source) DO UPDATE SET
    ip = coalesce(EXCLUDED.ip, fd.login_event.ip),
    ua = coalesce(EXCLUDED.ua, fd.login_event.ua),
    ua_app = coalesce(EXCLUDED.ua_app, fd.login_event.ua_app),
    ua_os = coalesce(EXCLUDED.ua_os, fd.login_event.ua_os),
    country = coalesce(EXCLUDED.country, fd.login_event.country),
    region = coalesce(EXCLUDED.region, fd.login_event.region),
    isp = coalesce(EXCLUDED.isp, fd.login_event.isp),
    seen = greatest(EXCLUDED.seen, fd.login_event.seen),
    first_seen_at = least(EXCLUDED.first_seen_at, fd.login_event.first_seen_at),
    updated_at = now()
WHERE (fd.login_event.ip, fd.login_event.ua, fd.login_event.ua_app, fd.login_event.ua_os,
       fd.login_event.country, fd.login_event.region, fd.login_event.isp, fd.login_event.seen,
       fd.login_event.first_seen_at)
      IS DISTINCT FROM (coalesce(EXCLUDED.ip, fd.login_event.ip),
                        coalesce(EXCLUDED.ua, fd.login_event.ua),
                        coalesce(EXCLUDED.ua_app, fd.login_event.ua_app),
                        coalesce(EXCLUDED.ua_os, fd.login_event.ua_os),
                        coalesce(EXCLUDED.country, fd.login_event.country),
                        coalesce(EXCLUDED.region, fd.login_event.region),
                        coalesce(EXCLUDED.isp, fd.login_event.isp),
                        greatest(EXCLUDED.seen, fd.login_event.seen),
                        least(EXCLUDED.first_seen_at, fd.login_event.first_seen_at))
"""


def stamp(seconds):
    try:
        return datetime.fromtimestamp(int(seconds), tz=UTC)
    except (TypeError, ValueError, OSError):
        return None


def normalized(value):
    held = str(value or "").strip()
    return held or None


def row_for(login):
    user_id = normalized(login.get("user_id"))
    at = stamp(login.get("date_last") or login.get("date_first"))
    if not user_id or at is None:
        return None

    ip = normalized(login.get("ip"))
    seen = useragent.parse(login.get("user_agent"))
    try:
        count = max(1, int(login.get("count") or 1))
    except (TypeError, ValueError):
        count = 1

    return (
        user_id, at, ip, seen["ua"], seen["ua_app"], seen["ua_os"],
        normalized(login.get("country")), normalized(login.get("region")), normalized(login.get("isp")),
        count, stamp(login.get("date_first")),
    )


def insert_rows(conn, logins, counts):
    rows = []
    for login in logins:
        row = row_for(login)
        if row is None:
            counts.rows_rejected += 1
            dead_letter(conn, SOURCE, {"keys": sorted(login)}, "no user_id or no date")
            continue
        rows.append(row)

    if rows:
        with conn.cursor() as cur:
            cur.executemany(ROW_SQL, rows)
            member_seen.logged_in(cur, [(row[0], row[1]) for row in rows])
    conn.commit()
    counts.rows_in += len(rows)
    return len(rows)


def newest_held(conn):
    row = conn.execute(NEWEST_SQL).fetchone()
    return row[0] if row else None


def run(conn, client=None):
    client = client or ProxyClient.for_source(SOURCE)
    since = newest_held(conn)
    stop_at = since - timedelta(seconds=LAP_SECONDS) if since else None

    held = []
    landed = 0
    caught_up = False

    with ingest_run(conn, SOURCE) as counts:
        def flush():
            nonlocal landed
            if not held:
                return
            landed += insert_rows(conn, held, counts)
            held.clear()

        walk = client.paginate(
            METHOD, {}, "logins", page_size=PAGE, cursor_param="cursor",
            credential=CREDENTIAL, page_param="limit",
            cursor_field="response_metadata.next_cursor",
        )
        for login in walk:
            when = stamp(login.get("date_last") or login.get("date_first"))
            if stop_at is not None and when is not None and when < stop_at:
                caught_up = True
                break
            held.append(login)
            if len(held) >= PAGE * MOST_PAGES:
                break
            if len(held) % PAGE == 0:
                flush()
        walk.close()
        flush()

    state = "up to date" if caught_up else "more to walk"
    print(f"{SOURCE}: {landed} login row(s), {state}")
    return landed


def backfill_start(conn):
    marker = get_cursor(conn, BACKFILL, max_age_hours=BACKFILL_MARKER_MAX_AGE_HOURS)
    if marker == BACKFILL_COMPLETE:
        return None
    if marker and marker.isdigit():
        return int(marker)
    row = conn.execute(OLDEST_SQL).fetchone()
    oldest = row[0] if row and row[0] else datetime.now(UTC)
    return int(oldest.timestamp())


def next_before(before, oldest_first_seen):
    candidate = int(oldest_first_seen.timestamp())
    return candidate if candidate < before else before - 1


def backfill(conn, client=None):
    before = backfill_start(conn)
    if before is None:
        return 0

    client = client or ProxyClient.for_source(BACKFILL)
    batch = []
    landed = 0
    taken = 0
    oldest = None
    capped = False

    with ingest_run(conn, BACKFILL) as counts:
        def flush():
            nonlocal landed
            if batch:
                landed += insert_rows(conn, batch, counts)
                batch.clear()
            if oldest is not None:
                save_cursor(conn, BACKFILL, str(next_before(before, oldest)))
                conn.commit()

        entries = client.paginate(
            METHOD, {"before": before}, "logins", page_size=PAGE, cursor_param="cursor",
            credential=CREDENTIAL, page_param="limit",
            cursor_field="response_metadata.next_cursor",
            on_page=lambda _cursor, _seen: flush(),
        )
        for login in entries:
            first_seen = stamp(login.get("date_first"))
            if first_seen is not None and (oldest is None or first_seen < oldest):
                oldest = first_seen
            batch.append(login)
            taken += 1
            if taken >= PAGE * MOST_PAGES:
                capped = True
                break
        entries.close()
        flush()
        if not capped:
            save_cursor(conn, BACKFILL, BACKFILL_COMPLETE)
            conn.commit()

    reached = f"first seen {oldest:%Y-%m-%d %H:%M}" if oldest else "no entries"
    state = "more to walk" if capped else "complete"
    print(f"{BACKFILL}: {landed} login row(s), {reached}, {state}")
    return landed
