import collections
from datetime import date, datetime, time, timedelta, timezone

from ingest.channel_range_pull import MONTH_SOURCE as CHANNEL_MONTH_SOURCE
from lib.db import connect_admin
from seed import SEED_SOURCE_PREFIX, SEED_USER_PREFIX
from seed import dims as dims_module
from seed import directory as directory_module
from seed import hostile as hostile_module
from seed import runs as runs_module
from seed import spine as spine_module
from seed.generate import COVERED_DAYS, Sampler

MEMBER_DAY_SOURCE = f"{SEED_SOURCE_PREFIX}member_day"
CHANNEL_DAY_SOURCE = f"{SEED_SOURCE_PREFIX}channel_day"
MEMBER_RANGE_SOURCE = "admin_analytics_member_range"
CHANNEL_RANGE_SOURCE = "admin_analytics_channel_range"
TEAM_SOURCE = f"{SEED_SOURCE_PREFIX}team_stats"
TOP_POSTER_WINDOWS = (7, 30, 90)
TOP_POSTER_LIMIT = 50
UNAVAILABLE_DAYS = 3
UNAVAILABLE_OFFSET = 2
IDLE_ROWS_PER_DAY = 25

SEEDED_TABLES = (
    "raw.member_dim_snapshot",
    "raw.channel_dim_snapshot",
    "raw.message_observation",
    "raw.thread",
    "raw.message",
    "raw.channel_walk",
    "raw.member_activity_snapshot",
    "raw.channel_activity_snapshot",
    "raw.team_stats_snapshot",
    "raw.top_posters_snapshot",
    "raw.message_activity_snapshot",
    "raw.analytics_day",
    "raw.member_message_history",
    "raw.member_first_reply",
    "raw.member_channel_message",
    "raw.member_channel_membership",
    "raw.member_channel_walk",
    "raw.top_posters_snapshot",
    "raw.member_dim",
    "raw.channel_dim",
    "fd.member_identity",
    "fd.member",
)

LOG_TABLES = (
    "raw.ingest_step_output",
    "raw.ingest_run",
    "raw.dead_letter",
)

UNSTAMP_SQL = """
UPDATE raw.deployment SET
    mode = 'live',
    seeded_at = NULL,
    seed_profile = NULL,
    seed_scale = NULL,
    seed_rng = NULL,
    updated_at = now()
"""

STAMP_SQL = """
UPDATE raw.deployment SET
    mode = 'seeded',
    seeded_at = now(),
    seed_profile = %s,
    seed_scale = %s,
    seed_rng = %s,
    updated_at = now()
"""


def noon(day):
    return datetime.combine(day, time(12, 0), tzinfo=timezone.utc)


def clear_seeded_staff():
    with connect_admin() as admin:
        admin.execute(f"DELETE FROM app.staff WHERE user_id LIKE '{SEED_USER_PREFIX}%'")
        admin.commit()


def unstamp(conn):
    with conn.cursor() as cur:
        cur.execute(UNSTAMP_SQL)
    conn.commit()


def clear(conn, force=False):
    clear_seeded_staff()
    with conn.cursor() as cur:
        for table in LOG_TABLES:
            cur.execute(f"DELETE FROM {table}")
        for table in dict.fromkeys(SEEDED_TABLES):
            if force:
                cur.execute(f"DELETE FROM {table}")
            elif has_column(cur, table, "channel_id"):
                cur.execute(f"DELETE FROM {table} WHERE channel_id LIKE 'CSEED%'")
            elif has_column(cur, table, "user_id"):
                cur.execute(f"DELETE FROM {table} WHERE user_id LIKE 'USEED%'")
            else:
                cur.execute(f"DELETE FROM {table} WHERE source LIKE %s", (f"{SEED_SOURCE_PREFIX}%",))
    conn.commit()


def has_column(cur, table, column):
    schema, name = table.split(".")
    cur.execute(
        "SELECT 1 FROM information_schema.columns "
        "WHERE table_schema = %s AND table_name = %s AND column_name = %s",
        (schema, name, column),
    )
    return cur.fetchone() is not None


def copy_rows(conn, table, columns, rows):
    written = 0
    with conn.cursor() as cur, cur.copy(
        f"COPY {table} ({', '.join(columns)}) FROM STDIN"
    ) as copy:
        for row in rows:
            copy.write_row(row)
            written += 1
    return written


def fold(stream):
    by_member = collections.defaultdict(lambda: [0, 0])
    by_channel = collections.defaultdict(lambda: [0, 0, set()])
    totals = collections.Counter()
    first_seen = {}
    for event in stream:
        member = by_member[(event.user_id, event.day)]
        member[0] += event.messages
        member[1] += event.reactions
        channel = by_channel[(event.channel_id, event.day)]
        channel[0] += event.messages
        channel[1] += event.reactions
        channel[2].add(event.user_id)
        totals[event.user_id] += event.messages
        first_seen.setdefault(event.channel_id, event.day)
        if event.day > first_seen[event.channel_id]:
            first_seen[event.channel_id] = event.day
    return by_member, by_channel, totals, first_seen


def member_days(by_member):
    for (user_id, day), (messages, reactions) in by_member.items():
        yield (
            user_id, day, day, MEMBER_DAY_SOURCE, 1, messages, messages, reactions, noon(day),
        )


def idle_days(by_member, members, start, days, holes):
    alive = sorted(members, key=lambda m: m.cohort_at)
    for offset in range(days):
        day = start + timedelta(days=offset)
        if day in holes:
            continue
        emitted = 0
        for member in alive:
            if emitted >= IDLE_ROWS_PER_DAY:
                break
            if member.cohort_at > day:
                break
            if member.deactivated_at and member.deactivated_at < day:
                continue
            if (member.user_id, day) in by_member:
                continue
            emitted += 1
            yield (member.user_id, day, day, MEMBER_DAY_SOURCE, 0, 0, 0, 0, None)


def channel_days(by_channel, members_of):
    for (channel_id, day), (messages, reactions, posters) in by_channel.items():
        total, guests = members_of[channel_id]
        yield (
            channel_id, day, day, CHANNEL_DAY_SOURCE, messages, messages,
            len(posters), len(posters) * 3, reactions, max(1, len(posters) // 2), 0,
            total, total - guests, guests,
        )


def member_ranges(by_member, start, end):
    rolled = collections.defaultdict(lambda: [0, 0, 0])
    for (user_id, _), (messages, reactions) in by_member.items():
        row = rolled[user_id]
        row[0] += 1
        row[1] += messages
        row[2] += reactions
    for user_id, (days, messages, reactions) in rolled.items():
        yield (
            user_id, start, end, MEMBER_RANGE_SOURCE, days, messages, messages, reactions,
            noon(end),
        )


def channel_membership(channels):
    return {c.channel_id: (c.total_members, c.guests) for c in channels}


def channel_ranges(by_channel, start, end, members_of):
    rolled = collections.defaultdict(lambda: [0, 0, set()])
    for (channel_id, _), (messages, reactions, posters) in by_channel.items():
        row = rolled[channel_id]
        row[0] += messages
        row[1] += reactions
        row[2] |= posters
    for channel_id, (messages, reactions, posters) in rolled.items():
        total, guests = members_of[channel_id]
        yield (
            channel_id, start, end, CHANNEL_RANGE_SOURCE, messages, messages,
            len(posters), len(posters) * 3, reactions, max(1, len(posters) // 2), 0,
            total, total - guests, guests,
        )


def channel_months(by_channel, members_of):
    rolled = collections.defaultdict(lambda: [0, 0, set()])
    for (channel_id, day), (messages, reactions, posters) in by_channel.items():
        row = rolled[(channel_id, day.replace(day=1))]
        row[0] += messages
        row[1] += reactions
        row[2] |= posters
    for (channel_id, month), (messages, reactions, posters) in rolled.items():
        total, guests = members_of[channel_id]
        last = month_end(month)
        yield (
            channel_id, month, last, CHANNEL_MONTH_SOURCE, messages, messages,
            len(posters), len(posters) * 3, reactions, max(1, len(posters) // 2), 0,
            total, total - guests, guests,
        )


def month_end(month):
    nxt = date(month.year + month.month // 12, month.month % 12 + 1, 1)
    return nxt - timedelta(days=1)


def team_days(by_member, channels, members, start, days):
    joined = collections.Counter()
    claimed = collections.Counter()
    guests = collections.Counter()
    for member in members:
        joined[member.cohort_at] += 1
        if member.claimed_at:
            claimed[member.claimed_at] += 1
        if member.is_restricted or member.is_ultra_restricted:
            guests[member.cohort_at] += 1

    daily = collections.defaultdict(set)
    messages = collections.Counter()
    for (user_id, day), (count, _) in by_member.items():
        daily[day].add(user_id)
        messages[day] += count

    everyone = sorted(joined)
    running = running_claimed = running_guests = 0
    cursor = 0
    window = collections.deque()
    for offset in range(days):
        day = start + timedelta(days=offset)
        while cursor < len(everyone) and everyone[cursor] <= day:
            running += joined[everyone[cursor]]
            running_claimed += claimed.get(everyone[cursor], 0)
            running_guests += guests.get(everyone[cursor], 0)
            cursor += 1
        window.append(daily.get(day, set()))
        while len(window) > 28:
            window.popleft()
        active_28 = len(set().union(*window)) if window else 0
        active_7 = len(set().union(*list(window)[-7:])) if window else 0
        active = len(daily.get(day, set()))
        yield (
            day, TEAM_SOURCE, running, running_claimed, running - running_guests,
            running_guests, active, active_7, active_28, active, active_7, active_28,
            active * 3, messages[day], messages[day], len(channels),
        )


def top_posters(rng, by_member, end, hostile=False):
    for window in TOP_POSTER_WINDOWS:
        start = end - timedelta(days=window - 1)
        totals = collections.Counter()
        for (user_id, day), (messages, _) in by_member.items():
            if start <= day <= end:
                totals[user_id] += messages
        for user_id, messages in totals.most_common(TOP_POSTER_LIMIT):
            yield (
                start, end, user_id,
                hostile_module.display_name(rng, user_id, hostile), messages, noon(end),
            )


def analytics_days(start, days, holes):
    for offset in range(days):
        day = start + timedelta(days=offset)
        blocked = day in holes
        for source in (MEMBER_DAY_SOURCE, CHANNEL_DAY_SOURCE):
            yield (source, day, not blocked, None if blocked else 1, blocked or None,
                   "seeded gap" if blocked else None)


def member_dim_rows(members, totals):
    for member in members:
        yield (
            member.user_id,
            joined_at(member),
            joined_at(member),
            joined_at(member) if member.claimed_at else None,
            noon(member.deactivated_at) if member.deactivated_at else None,
            member.deactivated_at is not None,
            member.invite_pending,
            not member.invite_pending,
            False,
            member.is_bot,
            member.is_admin,
            False,
            False,
            member.is_restricted,
            member.is_ultra_restricted,
        )


def channel_dim_rows(channels, last_active):
    for channel in channels:
        yield (
            channel.channel_id,
            channel.name,
            channel.visibility,
            channel.archived,
            noon(channel.date_created),
            noon(last_active[channel.channel_id]) if channel.channel_id in last_active else None,
            False,
        )


def joined_at(member):
    return datetime.combine(member.cohort_at, time(0, 0), tzinfo=timezone.utc)


def posted_at(member):
    if not member.first_post_at:
        return None
    return joined_at(member) + timedelta(hours=member.first_post_delay_hours)


def history_rows(members, totals, as_of):
    for member in members:
        yield (
            member.user_id,
            totals.get(member.user_id, 0) + member.total_messages,
            posted_at(member),
            member.first_post_channel,
            noon(as_of),
            as_of,
        )


def first_reply_rows(rng, members, profile, hostile=False):
    shares = profile["replies"]
    human = Sampler(shares["latency_seconds"])
    bot = Sampler(shares["bot_latency_seconds"])
    for member in members:
        if not member.first_post_at:
            continue
        roll = rng.random()
        posted = posted_at(member)
        bot_latency = int(max(1, bot(rng.random()))) if rng.random() < shares["bot_first_share"] else None
        bot_ts = posted + timedelta(seconds=bot_latency) if bot_latency else None
        if roll < shares["human_share"]:
            latency = int(max(1, human(rng.random())))
            yield (
                member.user_id, f"USEED{rng.randrange(1000):07d}",
                posted + timedelta(seconds=latency), latency, False, None,
                bot_latency and f"USEED{rng.randrange(50):07d}", bot_ts, bot_latency, 2,
            )
        elif roll < shares["human_share"] + shares["bot_only_share"]:
            latency = int(max(1, bot(rng.random())))
            yield (
                member.user_id, None, None, None, False, None,
                f"USEED{rng.randrange(50):07d}", posted + timedelta(seconds=latency), latency, 2,
            )
        elif roll < shares["human_share"] + shares["bot_only_share"] + 0.02:
            yield (
                member.user_id, None, None, None, True,
                hostile_module.reason(rng, "thread unreadable", hostile),
                None, None, None, 2,
            )
        else:
            yield (member.user_id, None, None, None, False, None, None, None, None, 2)


def write(conn, channels, members, profile, as_of, rng, stream, scale, seed,
          days=COVERED_DAYS, hostile=False):
    start = as_of - timedelta(days=days - 1)
    holes = {start + timedelta(days=UNAVAILABLE_OFFSET + i) for i in range(UNAVAILABLE_DAYS)}
    kept = [event for event in stream if event.day not in holes]
    by_member, by_channel, totals, last_active = fold(kept)

    counts = {}
    counts["member_dim"] = copy_rows(
        conn, "raw.member_dim",
        ["user_id", "account_created", "account_created_verified", "claimed_at",
         "deactivated_at", "is_deleted", "invite_pending",
         "is_invited_member", "is_invited_guest", "is_bot", "is_admin", "is_owner",
         "is_primary_owner", "is_restricted", "is_ultra_restricted"],
        member_dim_rows(members, totals),
    )
    counts["channel_dim"] = copy_rows(
        conn, "raw.channel_dim",
        ["channel_id", "name", "visibility", "archived", "date_created", "last_active_at",
         "name_unavailable"],
        channel_dim_rows(channels, last_active),
    )
    counts["member_message_history"] = copy_rows(
        conn, "raw.member_message_history",
        ["user_id", "total_messages", "first_post_ts", "first_post_channel", "searched_at",
         "counted_through"],
        history_rows(members, totals, as_of),
    )
    counts["member_first_reply"] = copy_rows(
        conn, "raw.member_first_reply",
        ["user_id", "replier_id", "reply_ts", "latency_seconds", "unreadable", "reason",
         "bot_replier_id", "bot_reply_ts", "bot_latency_seconds", "walk_version"],
        first_reply_rows(rng, members, profile, hostile),
    )

    member_columns = ["user_id", "window_start", "window_end", "source", "days_active",
                      "messages_posted", "channel_messages_posted", "reactions_added",
                      "last_active_at"]
    channel_columns = ["channel_id", "window_start", "window_end", "source", "messages_posted",
                       "messages_posted_by_members", "members_who_posted", "members_who_viewed",
                       "reactions_added", "members_who_reacted", "huddles_initiated",
                       "total_members", "full_members", "guests"]

    counts["member_day"] = copy_rows(
        conn, "raw.member_activity_snapshot", member_columns, member_days(by_member)
    )
    counts["member_day_idle"] = copy_rows(
        conn, "raw.member_activity_snapshot", member_columns,
        idle_days(by_member, members, start, days, holes),
    )
    counts["member_range"] = copy_rows(
        conn, "raw.member_activity_snapshot", member_columns,
        member_ranges(by_member, start, as_of),
    )
    members_of = channel_membership(channels)
    counts["channel_day"] = copy_rows(
        conn, "raw.channel_activity_snapshot", channel_columns,
        channel_days(by_channel, members_of),
    )
    counts["channel_range"] = copy_rows(
        conn, "raw.channel_activity_snapshot", channel_columns,
        channel_ranges(by_channel, start, as_of, members_of),
    )
    counts["channel_month"] = copy_rows(
        conn, "raw.channel_activity_snapshot", channel_columns,
        channel_months(by_channel, members_of),
    )
    counts["team_stats"] = copy_rows(
        conn, "raw.team_stats_snapshot",
        ["ds", "source", "total_members_count", "total_claimed_count", "full_members_count",
         "guests_count", "active_users_1d", "active_users_7d", "active_users_28d",
         "writers_count_1d", "writers_count_7d", "writers_count_28d", "readers_count_1d",
         "messages_count_1d", "chats_channels_count_1d", "channels_count"],
        team_days(by_member, channels, members, start, days),
    )
    counts["top_posters"] = copy_rows(
        conn, "raw.top_posters_snapshot",
        ["window_start", "window_end", "user_id", "display_name", "messages_posted", "pulled_at"],
        top_posters(rng, by_member, as_of, hostile),
    )
    counts["analytics_day"] = copy_rows(
        conn, "raw.analytics_day", ["source", "ds", "loaded", "rows_in", "unavailable", "reason"],
        analytics_days(start, days, holes),
    )

    messages, threads, walks, observations = spine_module.build(rng, kept, members, as_of)
    counts["message"] = copy_rows(
        conn, "raw.message", spine_module.MESSAGE_COLUMNS, messages
    )
    counts["thread"] = copy_rows(
        conn, "raw.thread", spine_module.THREAD_COLUMNS, threads
    )
    counts["channel_walk"] = copy_rows(
        conn, "raw.channel_walk", spine_module.WALK_COLUMNS, walks
    )
    counts["message_observation"] = copy_rows(
        conn, "raw.message_observation", spine_module.OBSERVATION_COLUMNS, observations
    )

    counts["member_dim_snapshot"] = copy_rows(
        conn, "raw.member_dim_snapshot", dims_module.MEMBER_COLUMNS,
        dims_module.member_rows(rng, members, as_of),
    )
    counts["channel_dim_snapshot"] = copy_rows(
        conn, "raw.channel_dim_snapshot", dims_module.CHANNEL_COLUMNS,
        dims_module.channel_rows(rng, channels, as_of),
    )
    dims_module.rehash(conn)

    with conn.cursor() as cur:
        cur.execute(STAMP_SQL, (profile["captured_at"], scale, seed))
    conn.commit()
    return counts


RUN_COLUMNS = ["source", "started_at", "finished_at", "status", "rows_in", "rows_rejected",
               "total_expected", "parent_run_id", "step_index", "step_total"]


def write_directory(conn, seed, members, as_of):
    profiles = directory_module.profiles_for(directory_module.rng_for(seed), members, as_of)
    return {
        "fd.member": copy_rows(
            conn, "fd.member", directory_module.MEMBER_COLUMNS,
            directory_module.member_rows(profiles, members),
        ),
        "fd.member_identity": copy_rows(
            conn, "fd.member_identity", directory_module.IDENTITY_COLUMNS,
            directory_module.identity_rows(profiles, members),
        ),
    }


def write_runs(conn, rng, members, as_of, hostile=False):
    parent_ids = []
    with conn.cursor() as cur:
        for row in runs_module.parent_rows(rng, as_of):
            cur.execute(
                f"INSERT INTO raw.ingest_run ({', '.join(RUN_COLUMNS)}) "
                f"VALUES ({', '.join(['%s'] * len(RUN_COLUMNS))}) RETURNING id",
                row,
            )
            parent_ids.append(cur.fetchone()[0])

    counts = {
        "ingest_run": len(parent_ids) + copy_rows(
            conn, "raw.ingest_run", RUN_COLUMNS,
            runs_module.child_rows(rng, as_of, parent_ids),
        ),
        "ingest_step_output": copy_rows(
            conn, "raw.ingest_step_output",
            ["parent_run_id", "step_index", "source", "output"],
            runs_module.step_output_rows(rng, parent_ids, hostile),
        ),
        "dead_letter": copy_rows(
            conn, "raw.dead_letter", ["source", "payload", "reason", "created_at"],
            runs_module.dead_letter_rows(rng, as_of, hostile=hostile),
        ),
    }
    conn.commit()
    return counts


def analyze(conn):
    notices = []
    conn.add_notice_handler(lambda diag: notices.append(diag.message_primary))
    with conn.cursor() as cur:
        for table in ("raw.member_activity_snapshot", "raw.channel_activity_snapshot"):
            cur.execute(f"ANALYZE {table}")
    conn.commit()
    return notices
