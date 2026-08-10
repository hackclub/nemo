import collections
from datetime import datetime, time, timedelta, timezone

from seed import SEED_SOURCE_PREFIX
from seed import runs as runs_module
from seed.generate import COVERED_DAYS, Sampler

MEMBER_DAY_SOURCE = f"{SEED_SOURCE_PREFIX}member_day"
CHANNEL_DAY_SOURCE = f"{SEED_SOURCE_PREFIX}channel_day"
MEMBER_RANGE_SOURCE = f"{SEED_SOURCE_PREFIX}member_range"
CHANNEL_RANGE_SOURCE = f"{SEED_SOURCE_PREFIX}channel_range"
TEAM_SOURCE = f"{SEED_SOURCE_PREFIX}team_stats"
TOP_POSTER_WINDOWS = (7, 30, 90)
TOP_POSTER_LIMIT = 50
UNAVAILABLE_DAYS = 3
UNAVAILABLE_OFFSET = 2
IDLE_ROWS_PER_DAY = 25

SEEDED_TABLES = (
    "raw.member_activity_snapshot",
    "raw.channel_activity_snapshot",
    "raw.team_stats_snapshot",
    "raw.top_posters_snapshot",
    "raw.message_activity_snapshot",
    "raw.analytics_day",
    "raw.member_message_history",
    "raw.member_first_reply",
    "raw.top_posters_snapshot",
    "raw.member_dim",
    "raw.channel_dim",
)

LOG_TABLES = (
    "raw.ingest_step_output",
    "raw.ingest_run",
    "raw.dead_letter",
    "raw.slack_events",
)

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


def clear(conn, force=False):
    with conn.cursor() as cur:
        for table in LOG_TABLES:
            cur.execute(f"DELETE FROM {table}")
        for table in dict.fromkeys(SEEDED_TABLES):
            if force:
                cur.execute(f"DELETE FROM {table}")
            elif has_source(cur, table):
                cur.execute(f"DELETE FROM {table} WHERE source LIKE %s", (f"{SEED_SOURCE_PREFIX}%",))
            elif table == "raw.channel_dim":
                cur.execute("DELETE FROM raw.channel_dim WHERE channel_id LIKE 'CSEED%'")
            else:
                cur.execute(f"DELETE FROM {table} WHERE user_id LIKE 'USEED%'")
    conn.commit()


def has_source(cur, table):
    schema, name = table.split(".")
    cur.execute(
        "SELECT 1 FROM information_schema.columns "
        "WHERE table_schema = %s AND table_name = %s AND column_name = 'source'",
        (schema, name),
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


def channel_days(by_channel):
    for (channel_id, day), (messages, reactions, posters) in by_channel.items():
        yield (
            channel_id, day, day, CHANNEL_DAY_SOURCE, messages, messages,
            len(posters), len(posters) * 3, reactions, max(1, len(posters) // 2), 0,
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


def channel_ranges(by_channel, start, end):
    rolled = collections.defaultdict(lambda: [0, 0, set()])
    for (channel_id, _), (messages, reactions, posters) in by_channel.items():
        row = rolled[channel_id]
        row[0] += messages
        row[1] += reactions
        row[2] |= posters
    for channel_id, (messages, reactions, posters) in rolled.items():
        yield (
            channel_id, start, end, CHANNEL_RANGE_SOURCE, messages, messages,
            len(posters), len(posters) * 3, reactions, max(1, len(posters) // 2), 0,
        )


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


def top_posters(by_member, end):
    for window in TOP_POSTER_WINDOWS:
        start = end - timedelta(days=window - 1)
        totals = collections.Counter()
        for (user_id, day), (messages, _) in by_member.items():
            if start <= day <= end:
                totals[user_id] += messages
        for user_id, messages in totals.most_common(TOP_POSTER_LIMIT):
            yield (start, end, user_id, f"member {user_id[-4:]}", messages, noon(end))


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
            noon(member.cohort_at),
            noon(member.cohort_at),
            noon(member.claimed_at) if member.claimed_at else None,
            "team_join" if member.claimed_at else None,
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
            channel.total_members,
            channel.total_members - channel.guests,
            channel.guests,
            False,
        )


def history_rows(members, totals, as_of):
    for member in members:
        yield (
            member.user_id,
            totals.get(member.user_id, 0) + member.total_messages,
            noon(member.first_post_at) if member.first_post_at else None,
            member.first_post_channel,
            noon(as_of),
            as_of,
        )


def first_reply_rows(rng, members, profile):
    shares = profile["replies"]
    human = Sampler(shares["latency_seconds"])
    bot = Sampler(shares["bot_latency_seconds"])
    for member in members:
        if not member.first_post_at:
            continue
        roll = rng.random()
        posted = noon(member.first_post_at)
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
            yield (member.user_id, None, None, None, True, "thread unreadable", None, None, None, 2)
        else:
            yield (member.user_id, None, None, None, False, None, None, None, None, 2)


def write(conn, channels, members, profile, as_of, rng, stream, scale, seed, days=COVERED_DAYS):
    start = as_of - timedelta(days=days - 1)
    holes = {start + timedelta(days=UNAVAILABLE_OFFSET + i) for i in range(UNAVAILABLE_DAYS)}
    by_member, by_channel, totals, last_active = fold(
        event for event in stream if event.day not in holes
    )

    counts = {}
    counts["member_dim"] = copy_rows(
        conn, "raw.member_dim",
        ["user_id", "account_created", "account_created_verified", "claimed_at",
         "claimed_at_source", "deactivated_at", "is_deleted", "invite_pending",
         "is_invited_member", "is_invited_guest", "is_bot", "is_admin", "is_owner",
         "is_primary_owner", "is_restricted", "is_ultra_restricted"],
        member_dim_rows(members, totals),
    )
    counts["channel_dim"] = copy_rows(
        conn, "raw.channel_dim",
        ["channel_id", "name", "visibility", "archived", "date_created", "last_active_at",
         "total_members", "full_members", "guests", "name_unavailable"],
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
        first_reply_rows(rng, members, profile),
    )

    member_columns = ["user_id", "window_start", "window_end", "source", "days_active",
                      "messages_posted", "channel_messages_posted", "reactions_added",
                      "last_active_at"]
    channel_columns = ["channel_id", "window_start", "window_end", "source", "messages_posted",
                       "messages_posted_by_members", "members_who_posted", "members_who_viewed",
                       "reactions_added", "members_who_reacted", "huddles_initiated"]

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
    counts["channel_day"] = copy_rows(
        conn, "raw.channel_activity_snapshot", channel_columns, channel_days(by_channel)
    )
    counts["channel_range"] = copy_rows(
        conn, "raw.channel_activity_snapshot", channel_columns,
        channel_ranges(by_channel, start, as_of),
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
        top_posters(by_member, as_of),
    )
    counts["analytics_day"] = copy_rows(
        conn, "raw.analytics_day", ["source", "ds", "loaded", "rows_in", "unavailable", "reason"],
        analytics_days(start, days, holes),
    )

    with conn.cursor() as cur:
        cur.execute(STAMP_SQL, (profile["captured_at"], scale, seed))
    conn.commit()
    return counts


RUN_COLUMNS = ["source", "started_at", "finished_at", "status", "rows_in", "rows_rejected",
               "total_expected", "parent_run_id", "step_index", "step_total"]


def write_runs(conn, rng, members, as_of):
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
            runs_module.step_output_rows(rng, parent_ids),
        ),
        "dead_letter": copy_rows(
            conn, "raw.dead_letter", ["source", "payload", "reason", "created_at"],
            runs_module.dead_letter_rows(rng, as_of),
        ),
        "slack_events": copy_rows(
            conn, "raw.slack_events", ["event_type", "payload", "received_at"],
            runs_module.slack_event_rows(rng, members, as_of),
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
