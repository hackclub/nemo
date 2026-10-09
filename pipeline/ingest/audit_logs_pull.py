import os
import threading
from datetime import UTC, date, datetime, timedelta

from psycopg.types.json import Jsonb

from lib import coverage, member_seen, useragent
from lib.db import dead_letter, get_cursor, ingest_run, save_cursor
from lib.proxy_client import ProxyClient, ProxyError

METHOD = "audit.logs"
CREDENTIAL = "admin"
PAGE = 1000

TAIL = "audit_logs_tail"
BACKFILL = "audit_logs_backfill"
LOGIN_BACKFILL = "login_event_backfill"
LOGIN_BACKFILL_BATCH = 5000
LOGIN_BACKFILL_COMPLETE = "complete"
LOGIN_BACKFILL_MARKER_MAX_AGE_HOURS = 24 * 365

LOGIN_ACTIONS = (
    "user_login",
    "user_login_failed",
    "user_logout",
    "user_created",
    "user_joined_workspace",
    "guest_joined_workspace",
    "user_session_reset_by_admin",
    "user_session_invalidated",
    "anomaly",
)

LOGIN_SET = frozenset(LOGIN_ACTIONS)
SEATED = frozenset({"user_login", "user_login_failed", "anomaly"})
SESSION_START = "user_login"
NOT_OWN_SESSION = frozenset({"INVITED", "KICKED"})

CHANNEL_MEMBERSHIP_ACTIONS = ("user_channel_join", "user_channel_leave")
LOGIN_AND_CHANNEL_ACTIONS = LOGIN_ACTIONS + CHANNEL_MEMBERSHIP_ACTIONS
IDENTITY_ACTIONS = LOGIN_ACTIONS + ("user_deactivated", "user_reactivated", "user_profile_updated")

ACTION_SETS = {
    "login_and_channel": LOGIN_AND_CHANNEL_ACTIONS,
    "login": LOGIN_ACTIONS,
    "channel_membership": CHANNEL_MEMBERSHIP_ACTIONS,
    "identity": IDENTITY_ACTIONS,
}
DEFAULT_BACKFILL_SETS = ("login_and_channel",)
JOINED = "joined"
LEFT = "left"
ROOMED = {"user_channel_join": JOINED, "user_channel_leave": LEFT}

DEFAULT_HORIZON_DAYS = 90
LAP_SECONDS = 1
FIRST_TAIL_HOURS = 24

EVENT_SQL = """
INSERT INTO slack.audit_event
    (id, at, action, actor_kind, actor_id, entity_kind, entity_id, app_id, ours,
     context, payload, source_key)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (id) DO NOTHING
"""

LOGIN_SQL = """
INSERT INTO fd.login_event
    (user_id, at, source, action, ip, ua, ua_app, ua_os, session_id, ua_read_at)
VALUES (%s, %s, 'audit_logs', %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (user_id, at, source) DO UPDATE SET
    ip = coalesce(EXCLUDED.ip, fd.login_event.ip),
    ua = coalesce(EXCLUDED.ua, fd.login_event.ua),
    ua_app = coalesce(EXCLUDED.ua_app, fd.login_event.ua_app),
    ua_os = coalesce(EXCLUDED.ua_os, fd.login_event.ua_os),
    session_id = coalesce(EXCLUDED.session_id, fd.login_event.session_id),
    updated_at = now()
WHERE (fd.login_event.ip, fd.login_event.ua, fd.login_event.ua_app, fd.login_event.ua_os,
       fd.login_event.session_id)
      IS DISTINCT FROM (coalesce(EXCLUDED.ip, fd.login_event.ip),
                        coalesce(EXCLUDED.ua, fd.login_event.ua),
                        coalesce(EXCLUDED.ua_app, fd.login_event.ua_app),
                        coalesce(EXCLUDED.ua_os, fd.login_event.ua_os),
                        coalesce(EXCLUDED.session_id, fd.login_event.session_id))
"""

IDENTITY_SQL = """
INSERT INTO fd.member_identity (user_id, real_name, email, updated_at)
SELECT %s, %s, %s, now()
WHERE EXISTS (SELECT 1 FROM fd.member m WHERE m.user_id = %s)
ON CONFLICT (user_id) DO UPDATE SET
    email = coalesce(fd.member_identity.email, EXCLUDED.email),
    real_name = coalesce(fd.member_identity.real_name, EXCLUDED.real_name),
    updated_at = now()
WHERE fd.member_identity.purged_at IS NULL
  AND (fd.member_identity.email IS NULL OR fd.member_identity.real_name IS NULL)
"""

CHANNEL_SQL = """
INSERT INTO fd.member_channel_join
    (audit_id, at, user_id, channel_id, channel_name, privacy, verb, by_workflow)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (audit_id) DO NOTHING
"""

WATERMARK_SQL = "SELECT max(at) FROM slack.audit_event"

OWNERS_SQL = """
SELECT DISTINCT session_id, user_id FROM fd.login_event
WHERE session_id = ANY(%s) AND action = 'user_login'
"""

HELD_FIRST_SQL = """
SELECT id, at, action, actor_kind, actor_id, context, payload->'details'
FROM slack.audit_event
ORDER BY at DESC, id DESC
LIMIT %(batch)s
"""

HELD_NEXT_SQL = """
SELECT id, at, action, actor_kind, actor_id, context, payload->'details'
FROM slack.audit_event
WHERE (at, id) < (%(at)s, %(id)s)
ORDER BY at DESC, id DESC
LIMIT %(batch)s
"""


def horizon_days():
    try:
        return max(1, int(os.environ.get("AUDIT_HORIZON_DAYS", "") or DEFAULT_HORIZON_DAYS))
    except ValueError:
        return DEFAULT_HORIZON_DAYS


MOST_ACTIONS = 30
REFUSED = 400

_refused = set()
_refusals = threading.Lock()


def refused_actions():
    with _refusals:
        return frozenset(_refused)


def forget_refusals():
    with _refusals:
        _refused.clear()


def is_permission_denied(failure):
    return getattr(failure, "http_status", None) == REFUSED


def usable(actions):
    if not actions:
        return actions

    held = refused_actions()
    return tuple(one for one in actions if one not in held)


def find_refusals(client, actions):
    found = []
    for one in actions:
        try:
            client.call(METHOD, {"limit": 1, "action": one},
                        credential=CREDENTIAL, max_retries=0)
        except ProxyError as failure:
            if not is_permission_denied(failure):
                raise
            found.append(one)

    if found:
        with _refusals:
            _refused.update(found)
        log_refusals(found)
    return found


def log_refusals(found):
    print(f"{TAIL}: slack will not take {', '.join(sorted(found))}, leaving them out")


def tail_actions():
    raw = os.environ.get("AUDIT_TAIL_ACTIONS", "").strip()
    if not raw:
        return None
    if raw.lower() in ACTION_SETS:
        return ACTION_SETS[raw.lower()]
    return tuple(one.strip() for one in raw.split(",") if one.strip())[:MOST_ACTIONS]


def nemo_ids():
    raw = os.environ.get("AUDIT_NEMO_ID", "")
    return frozenset(one.strip() for one in raw.split(",") if one.strip())


def stamp(seconds):
    try:
        return datetime.fromtimestamp(int(seconds), tz=UTC)
    except (TypeError, ValueError, OSError):
        return None


def whose(entry, key):
    held = entry.get(key) or {}
    kind = held.get("type")
    if not kind:
        return None, None
    body = held.get(kind) or {}
    return kind, body.get("id")


def event_row(entry, source_key, ours):
    at = stamp(entry.get("date_create"))
    if not entry.get("id") or at is None or not entry.get("action"):
        return None

    context = entry.get("context") or {}
    app_id = ((context.get("app") or {}).get("id")) or None
    actor_kind, actor_id = whose(entry, "actor")
    entity_kind, entity_id = whose(entry, "entity")

    return (
        entry["id"], at, entry["action"], actor_kind, actor_id, entity_kind, entity_id,
        app_id, bool(app_id and app_id in ours), Jsonb(context), Jsonb(entry), source_key,
    )


def own_session(entry):
    context = entry.get("context") or {}
    if (context.get("app") or {}).get("id"):
        return False
    if str((entry.get("details") or {}).get("type") or "").upper() in NOT_OWN_SESSION:
        return False
    return not useragent.api_client(context.get("ua"))


def login_row(entry):
    kind, user_id = whose(entry, "actor")
    at = stamp(entry.get("date_create"))
    if not user_id or at is None:
        return None

    context = entry.get("context") or {}
    ip = (context.get("ip_address") or "").strip() or None
    if entry.get("action") not in SEATED:
        if kind != "user" or ip is None or not own_session(entry):
            return None
    seen = useragent.parse(context.get("ua"))
    session = context.get("session_id")

    return (
        user_id, at, entry["action"], ip,
        seen["ua"], seen["ua_app"], seen["ua_os"],
        int(session) if str(session or "").isdigit() else None,
    )


def identity_row(entry):
    who = (entry.get("actor") or {}).get("user") or {}
    if (entry.get("actor") or {}).get("type") != "user":
        return None

    user_id = who.get("id")
    email = (who.get("email") or "").strip() or None
    name = (who.get("name") or "").strip() or None
    if not user_id or email is None:
        return None

    return (user_id, name, email, user_id)


def channel_row(entry):
    verb = ROOMED.get(entry.get("action"))
    if verb is None:
        return None

    _kind, user_id = whose(entry, "actor")
    room = (entry.get("entity") or {}).get("channel") or {}
    at = stamp(entry.get("date_create"))
    if not entry.get("id") or not user_id or not room.get("id") or at is None:
        return None

    return (
        entry["id"], at, user_id, room["id"], room.get("name"), room.get("privacy"),
        verb, bool((entry.get("details") or {}).get("is_workflow")),
    )


def session_owners(conn, logins):
    sessions = sorted({row[7] for row in logins if row[7] is not None})
    owners = {}
    if sessions:
        for session, user_id in conn.execute(OWNERS_SQL, (sessions,)).fetchall():
            owners.setdefault(session, set()).add(user_id)
    for row in logins:
        if row[2] == SESSION_START and row[7] is not None:
            owners.setdefault(row[7], set()).add(row[0])
    return owners


def own_sessions(conn, logins):
    owners = session_owners(conn, logins)
    return [row for row in logins
            if row[2] == SESSION_START or row[7] is None
            or not owners.get(row[7]) or row[0] in owners[row[7]]]


def insert_rows(conn, entries, source_key, ours, counts):
    events, logins, rooms = [], [], []
    named = {}
    for entry in entries:
        row = event_row(entry, source_key, ours)
        if row is None:
            counts.rows_rejected += 1
            dead_letter(conn, source_key, {"keys": sorted(entry)}, "no id, action or date")
            continue
        events.append(row)
        seated = login_row(entry)
        if seated:
            logins.append(seated)
        roomed = channel_row(entry)
        if roomed:
            rooms.append(roomed)
        knew = identity_row(entry)
        if knew:
            named[knew[0]] = knew

    logins = own_sessions(conn, logins)
    if events:
        with conn.cursor() as cur:
            cur.executemany(EVENT_SQL, events)
            if logins:
                cur.executemany(LOGIN_SQL, logins)
                member_seen.logged_in(cur, [(row[0], row[1]) for row in logins if row[2] == "user_login"])
            if rooms:
                cur.executemany(CHANNEL_SQL, rooms)
            if named:
                cur.executemany(IDENTITY_SQL, list(named.values()))
    conn.commit()
    counts.rows_in += len(events)
    return len(events), len(logins)


def walk(client, conn, source_key, counts, oldest=None, latest=None, actions=None,
         start_cursor=None, on_cursor=None):
    asked = {}
    if oldest is not None:
        asked["oldest"] = int(oldest.timestamp())
    if latest is not None:
        asked["latest"] = int(latest.timestamp())
    held = usable(actions)
    if actions and not held:
        return 0, 0
    if held:
        asked["action"] = ",".join(held[:MOST_ACTIONS])

    ours = nemo_ids()
    held = []
    landed = seated = 0

    def flush():
        nonlocal landed, seated
        if not held:
            return
        grew, lit = insert_rows(conn, held, source_key, ours, counts)
        landed += grew
        seated += lit
        held.clear()

    def page_done(cursor, _page):
        flush()
        if on_cursor:
            on_cursor(cursor)

    def pages():
        return client.paginate(
            METHOD, asked, "entries", page_size=PAGE, cursor_param="cursor",
            credential=CREDENTIAL, page_param="limit",
            cursor_field="response_metadata.next_cursor",
            start_cursor=start_cursor, on_page=page_done, allow_empty_pages=True,
        )

    try:
        held.extend(pages())
    except ProxyError as failure:
        if not is_permission_denied(failure) or not held_actions(asked):
            raise
        if not find_refusals(client, held_actions(asked)):
            raise
        return walk(client, conn, source_key, counts, oldest=oldest, latest=latest,
                    actions=actions, start_cursor=start_cursor, on_cursor=on_cursor)

    flush()
    return landed, seated


def held_actions(asked):
    raw = asked.get("action")
    return tuple(raw.split(",")) if raw else ()


def watermark(conn):
    row = conn.execute(WATERMARK_SQL).fetchone()
    return row[0] if row and row[0] else None


WINDOW_MARK = "|"


def keep_place(conn, source_key, oldest, cursor):
    if not cursor:
        save_cursor(conn, source_key, "")
        return
    save_cursor(conn, source_key, f"{int(oldest.timestamp())}{WINDOW_MARK}{cursor}")


def held_place(conn, source_key):
    mark_and_cursor = get_cursor(conn, source_key) or ""
    mark, _, cursor = mark_and_cursor.partition(WINDOW_MARK)
    if not cursor or not mark.isdigit():
        return None, None
    return cursor, datetime.fromtimestamp(int(mark), tz=UTC)


def drop_cursor(conn, source_key):
    save_cursor(conn, source_key, "")
    conn.commit()


def tail(conn, client=None):
    client = client or ProxyClient.for_source(TAIL)
    held, window = held_place(conn, TAIL)

    if held:
        oldest = window
    else:
        since = watermark(conn) or datetime.now(UTC) - timedelta(hours=FIRST_TAIL_HOURS)
        oldest = since - timedelta(seconds=LAP_SECONDS)

    try:
        with ingest_run(conn, TAIL) as counts:
            landed, seated = walk(
                client, conn, TAIL, counts, oldest=oldest, actions=tail_actions(),
                start_cursor=held,
                on_cursor=lambda cursor: keep_place(conn, TAIL, oldest, cursor),
            )
            save_cursor(conn, TAIL, "")
    except ProxyError as failure:
        if held and is_permission_denied(failure):
            drop_cursor(conn, TAIL)
            print(f"{TAIL}: slack would not take the saved cursor, dropped it "
                  f"so the next pass starts from the watermark")
        raise

    print(f"{TAIL}: {landed} event(s), {seated} login(s) since {oldest:%Y-%m-%d %H:%M}")
    return landed


def slice_keys(days):
    today = datetime.now(UTC).date()
    return [today - timedelta(days=step) for step in range(days)]


def source_key_for(actions):
    if not actions:
        return f"{BACKFILL}:all"

    requested = tuple(actions)
    for name, known in ACTION_SETS.items():
        if requested == known:
            return f"{BACKFILL}:{name}"
    return f"{BACKFILL}:custom"


def backfill_set_names():
    raw = os.environ.get("AUDIT_BACKFILL_SETS", "")
    names = [one.strip().lower() for one in raw.split(",") if one.strip()]
    return tuple(dict.fromkeys(names)) or DEFAULT_BACKFILL_SETS


def unknown_backfill_sets():
    return tuple(name for name in backfill_set_names() if name not in ACTION_SETS)


def backfill_sets():
    return tuple(ACTION_SETS[name] for name in backfill_set_names() if name in ACTION_SETS)


def next_slice(conn, source_key, days):
    done = coverage.covered(conn, source_key)
    for day in slice_keys(days):
        if day.isoformat() not in done:
            return day
    return None


def bounds(day: date):
    start = datetime(day.year, day.month, day.day, tzinfo=UTC)
    return start, start + timedelta(days=1)


def backfill(conn, client=None, actions=LOGIN_AND_CHANNEL_ACTIONS):
    client = client or ProxyClient.for_source(BACKFILL)
    source_key = source_key_for(actions)
    day = next_slice(conn, source_key, horizon_days())
    if day is None:
        return 0

    slice_key = day.isoformat()
    start, stop = bounds(day)
    fence = coverage.claim_slice(conn, source_key, slice_key, start=day, stop=day)
    if fence is None:
        return 0

    try:
        with ingest_run(conn, BACKFILL, slice_key=slice_key) as counts:
            landed, seated = walk(client, conn, source_key, counts,
                                  oldest=start, latest=stop, actions=actions)
    except Exception as failure:
        coverage.settle_aside(source_key, slice_key, fence, "short", note=str(failure))
        raise

    coverage.settle(conn, source_key, slice_key, fence, "complete", landed=landed)
    conn.commit()
    print(f"{source_key} {slice_key}: {landed} event(s), {seated} login(s)")
    return landed


def backfill_next(conn, client=None):
    days = horizon_days()
    for actions in backfill_sets():
        if next_slice(conn, source_key_for(actions), days) is not None:
            return backfill(conn, client, actions)
    return 0


def run(conn):
    return tail(conn)


def held_entry(at, action, actor_kind, actor_id, context, details):
    actor = {"type": actor_kind, actor_kind: {"id": actor_id}} if actor_kind else {}
    return {"action": action, "date_create": int(at.timestamp()), "actor": actor,
            "context": context or {}, "details": details or {}}


def login_backfill_place(conn):
    marker = get_cursor(conn, LOGIN_BACKFILL, max_age_hours=LOGIN_BACKFILL_MARKER_MAX_AGE_HOURS)
    if marker == LOGIN_BACKFILL_COMPLETE:
        return LOGIN_BACKFILL_COMPLETE, None
    at, _, event_id = (marker or "").partition("|")
    if not at or not event_id:
        return None, None
    return datetime.fromisoformat(at), event_id


def backfill_logins(conn):
    at, event_id = login_backfill_place(conn)
    if at == LOGIN_BACKFILL_COMPLETE:
        return 0

    with ingest_run(conn, LOGIN_BACKFILL) as counts:
        if at is None:
            held = conn.execute(HELD_FIRST_SQL, {"batch": LOGIN_BACKFILL_BATCH}).fetchall()
        else:
            held = conn.execute(HELD_NEXT_SQL, {"at": at, "id": event_id,
                                                "batch": LOGIN_BACKFILL_BATCH}).fetchall()
        if not held:
            save_cursor(conn, LOGIN_BACKFILL, LOGIN_BACKFILL_COMPLETE)
            conn.commit()
            print(f"{LOGIN_BACKFILL}: every held event has been read, complete")
            return 0

        logins = [row for row in (login_row(held_entry(*one[1:])) for one in held) if row]
        logins = own_sessions(conn, logins)
        if logins:
            with conn.cursor() as cur:
                cur.executemany(LOGIN_SQL, logins)
        last = held[-1]
        save_cursor(conn, LOGIN_BACKFILL, f"{last[1].isoformat()}|{last[0]}")
        conn.commit()
        counts.rows_in += len(logins)

    print(f"{LOGIN_BACKFILL}: {len(held)} event(s) read back to {last[1]:%Y-%m-%d %H:%M}, "
          f"{len(logins)} login row(s)")
    return len(held)
