import ipaddress
import os
import threading
import uuid
from datetime import UTC, date, datetime, timedelta

from psycopg.types.json import Jsonb

from lib import audit_actions, coverage, member_seen, user_agents, useragent
from lib.db import dead_letter, get_cursor, ingest_run, save_cursor
from lib.proxy_client import ProxyClient, ProxyError

METHOD = "audit.logs"
CREDENTIAL = "admin"
PAGE = 1000

TAIL = "audit_logs_tail"
BACKFILL = "audit_logs_backfill"

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

MONTHS_AHEAD = 2

ENSURE_MONTHS_SQL = """
SELECT slack.ensure_months('slack.audit_event', 'audit_event', %(first)s, %(ahead)s),
       slack.ensure_months('slack.audit_view', 'audit_view', %(first)s, %(ahead)s)
"""

VIEW_CODES_SQL = "SELECT action, code FROM slack.audit_view_action"

MONTHLY_SQL = """
INSERT INTO slack.audit_event
    (id, at, action, category, actor_kind, actor_id, actor_email, entity_kind, entity_id,
     entity_email, channel_id, app_id, ours, ip, ua_id, session_id, source_key, payload)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (id, at) DO NOTHING
RETURNING id
"""

VIEW_SQL = """
INSERT INTO slack.audit_view (id, at, action, actor_id, object_id, ip, ua_id, session_id, ours)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (id, at) DO NOTHING
RETURNING id
"""

LOGIN_SQL = """
INSERT INTO fd.login_event AS held
    (user_id, source, hour, ip, ua_id, first_at, last_at, hits, logins, failures, anomalies, seen)
VALUES (%s, 'audit_logs', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (user_id, source, hour, ip, ua_id) DO UPDATE SET
    first_at = least(held.first_at, EXCLUDED.first_at),
    last_at = greatest(held.last_at, EXCLUDED.last_at),
    hits = held.hits + EXCLUDED.hits,
    logins = held.logins + EXCLUDED.logins,
    failures = held.failures + EXCLUDED.failures,
    anomalies = held.anomalies + EXCLUDED.anomalies,
    seen = held.seen + EXCLUDED.seen,
    updated_at = now()
"""

SESSION_SQL = """
INSERT INTO fd.login_session AS held (session_id, user_id, at)
VALUES (%s, %s, %s)
ON CONFLICT (session_id, user_id) DO UPDATE SET at = EXCLUDED.at
WHERE EXCLUDED.at < held.at
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

OWNERS_SQL = "SELECT session_id, user_id FROM fd.login_session WHERE session_id = ANY(%s)"


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


def landable(entry):
    return (event_uuid(entry.get("id")) is not None and stamp(entry.get("date_create")) is not None
            and bool(entry.get("action")))


def address(value):
    held = str(value or "").strip()
    if not held:
        return None
    try:
        return str(ipaddress.ip_address(held))
    except ValueError:
        return None


def own_session(entry):
    context = entry.get("context") or {}
    if (context.get("app") or {}).get("id"):
        return False
    if str((entry.get("details") or {}).get("type") or "").upper() in NOT_OWN_SESSION:
        return False
    return not useragent.api_client(context.get("ua"))


def session_of(context):
    session = (context or {}).get("session_id")
    return int(session) if str(session or "").isdigit() else None


def event_uuid(value):
    try:
        return uuid.UUID(str(value))
    except ValueError:
        return None


def email_of(entry, key):
    held = entry.get(key) or {}
    if held.get("type") != "user":
        return None
    email = str((held.get("user") or {}).get("email") or "").strip().lower()
    return email or None


def channel_of(entry):
    entity = entry.get("entity") or {}
    kind = entity.get("type")
    body = entity.get(kind) or {} if kind else {}
    if kind == "channel":
        found = body.get("id")
    else:
        found = body.get("channel") or body.get("channel_id")
    return found if isinstance(found, str) and found else None


def agent_of(entry):
    return str((entry.get("context") or {}).get("ua") or "").strip() or None


def monthly_row(entry, source_key, ours, agents, held):
    event_id = event_uuid(entry.get("id"))
    at = stamp(entry.get("date_create"))
    if event_id is None or at is None or not entry.get("action"):
        return None
    context = entry.get("context") or {}
    app_id = ((context.get("app") or {}).get("id")) or None
    actor_kind, actor_id = whose(entry, "actor")
    entity_kind, entity_id = whose(entry, "entity")
    agent = agent_of(entry)
    return (
        event_id, at, entry["action"], audit_actions.entry(entry["action"], held)["category"],
        actor_kind, actor_id, email_of(entry, "actor"), entity_kind, entity_id,
        email_of(entry, "entity"), channel_of(entry), app_id, bool(app_id and app_id in ours),
        address(context.get("ip_address")), user_agents.id_of(agents, agent),
        session_of(context), source_key, Jsonb(entry),
    )


def view_row(entry, code, agents, ours):
    event_id = event_uuid(entry.get("id"))
    at = stamp(entry.get("date_create"))
    if event_id is None or at is None:
        return None
    context = entry.get("context") or {}
    _actor_kind, actor_id = whose(entry, "actor")
    _entity_kind, entity_id = whose(entry, "entity")
    app_id = ((context.get("app") or {}).get("id")) or None
    agent = agent_of(entry)
    return (
        event_id, at, code, actor_id, entity_id, address(context.get("ip_address")),
        user_agents.id_of(agents, agent), session_of(context),
        bool(app_id and app_id in ours),
    )


def landed_ids(cur, sql, rows):
    if not rows:
        return set()
    cur.executemany(sql, rows, returning=True)
    return {row[0] for _ in cur.results() for row in cur.fetchall()}


def write_new_shape(conn, entries, source_key, ours):
    times = [at for at in (stamp(entry.get("date_create")) for entry in entries) if at is not None]
    if not times:
        return set(), {}
    conn.execute(ENSURE_MONTHS_SQL, {"first": min(times).date().replace(day=1), "ahead": MONTHS_AHEAD})
    held = audit_actions.catalogue()
    codes = dict(conn.execute(VIEW_CODES_SQL).fetchall())
    agents = user_agents.ids(conn, [agent_of(entry) for entry in entries])
    monthly, view = [], []
    for entry in entries:
        code = codes.get(entry.get("action"))
        if code:
            row = view_row(entry, code, agents, ours)
            if row:
                view.append(row)
        else:
            row = monthly_row(entry, source_key, ours, agents, held)
            if row:
                monthly.append(row)
    with conn.cursor() as cur:
        fresh = landed_ids(cur, MONTHLY_SQL, monthly) | landed_ids(cur, VIEW_SQL, view)
    return fresh, agents


def login_row(entry):
    kind, user_id = whose(entry, "actor")
    at = stamp(entry.get("date_create"))
    if not user_id or at is None:
        return None

    context = entry.get("context") or {}
    ip = address(context.get("ip_address"))
    if entry.get("action") not in SEATED:
        if kind != "user" or ip is None or not own_session(entry):
            return None
    return (
        user_id, at, entry["action"], ip, useragent.parse(context.get("ua"))["ua"],
        session_of(context), event_uuid(entry.get("id")),
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
    sessions = sorted({row[5] for row in logins if row[5] is not None})
    owners = {}
    if sessions:
        for session, user_id in conn.execute(OWNERS_SQL, (sessions,)).fetchall():
            owners.setdefault(session, set()).add(user_id)
    for row in logins:
        if row[2] == SESSION_START and row[5] is not None:
            owners.setdefault(row[5], set()).add(row[0])
    return owners


def own_sessions(conn, logins):
    owners = session_owners(conn, logins)
    return [row for row in logins
            if row[2] == SESSION_START or row[5] is None
            or not owners.get(row[5]) or row[0] in owners[row[5]]]


def session_rows(logins):
    first = {}
    for user_id, at, action, _ip, _ua, session, _event in logins:
        if action == SESSION_START and session is not None:
            key = (session, user_id)
            first[key] = min(at, first.get(key, at))
    return [(session, user_id, at) for (session, user_id), at in sorted(first.items())]


def hour_of(at):
    return at.astimezone(UTC).replace(minute=0, second=0, microsecond=0)


def hourly(logins, agents):
    latest = {}
    for row in logins:
        latest[(row[0], row[1])] = row
    held = {}
    for user_id, at, action, ip, ua, _session, _event in latest.values():
        key = (user_id, hour_of(at), ip, user_agents.id_of(agents, ua))
        first, last, hits, signed_in, failed, flagged = held.get(key, (at, at, 0, 0, 0, 0))
        held[key] = (min(first, at), max(last, at), hits + 1, signed_in + (action == SESSION_START),
                     failed + (action == "user_login_failed"), flagged + (action == "anomaly"))
    return [(*key, first, last, hits, signed_in, failed, flagged, hits)
            for key, (first, last, hits, signed_in, failed, flagged)
            in sorted(held.items(), key=lambda one: (one[0][0], one[0][1], str(one[0][2]), one[0][3] or 0))]


def insert_rows(conn, entries, source_key, ours, counts):
    logins, rooms, landed = [], [], []
    named = {}
    for entry in entries:
        if not landable(entry):
            counts.rows_rejected += 1
            dead_letter(conn, source_key, {"keys": sorted(entry)}, "no uuid id, action or date")
            continue
        landed.append(entry)
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
    if landed:
        fresh, agents = write_new_shape(conn, landed, source_key, ours)
        counted = hourly([row for row in logins if row[6] in fresh], agents)
        sessions = session_rows(logins)
        with conn.cursor() as cur:
            if counted:
                cur.executemany(LOGIN_SQL, counted)
            if sessions:
                cur.executemany(SESSION_SQL, sessions)
            if logins:
                member_seen.logged_in(cur, [(row[0], row[1]) for row in logins if row[2] == SESSION_START])
            if rooms:
                cur.executemany(CHANNEL_SQL, rooms)
            if named:
                cur.executemany(IDENTITY_SQL, list(named.values()))
    conn.commit()
    counts.rows_in += len(landed)
    return len(landed), len(logins)


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
