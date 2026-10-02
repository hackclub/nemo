from datetime import datetime, time, timedelta, timezone

from ingest.dim_snapshot import CHANNEL_HASH, MEMBER_HASH

SNAPSHOT_DAYS = 30
RENAME_SHARE = 0.06
ARCHIVE_SHARE = 0.04
ADMIN_SHARE = 0.02

MEMBER_COLUMNS = [
    "user_id", "observed_on", "record_hash", "account_created", "account_created_verified",
    "claimed_at", "deactivated_at", "is_bot", "is_admin", "is_owner", "is_primary_owner",
    "is_restricted", "is_ultra_restricted", "is_invited_member", "is_invited_guest",
    "is_deleted", "invite_pending", "observed_at",
]

CHANNEL_COLUMNS = [
    "channel_id", "observed_on", "record_hash", "name", "visibility", "archived",
    "date_created", "observed_at",
]

MEMBER_REHASH = f"""
UPDATE raw.member_dim_snapshot SET record_hash = {MEMBER_HASH} WHERE record_hash = ''
"""

CHANNEL_REHASH = f"""
UPDATE raw.channel_dim_snapshot SET record_hash = {CHANNEL_HASH} WHERE record_hash = ''
"""


def noon(day):
    return datetime.combine(day, time(12, 0), tzinfo=timezone.utc)


def midnight(day):
    return datetime.combine(day, time(0, 0), tzinfo=timezone.utc)


def window(as_of, days=SNAPSHOT_DAYS):
    start = as_of - timedelta(days=days - 1)
    return [start + timedelta(days=offset) for offset in range(days)]


def turns(rng, things, share, span):
    chosen = {}
    for thing in things:
        if rng.random() < share:
            chosen[thing] = span[rng.randrange(1, len(span))]
    return chosen


def member_rows(rng, members, as_of, days=SNAPSHOT_DAYS):
    span = window(as_of, days)
    alive = [member for member in members if member.cohort_at <= span[-1]]
    promoted = turns(rng, [m.user_id for m in alive if not m.is_admin], ADMIN_SHARE, span)
    stamped = noon(as_of)
    for day in span:
        for member in alive:
            if member.cohort_at > day:
                continue
            gone = member.deactivated_at is not None and member.deactivated_at <= day
            claimed = member.claimed_at is not None and member.claimed_at <= day
            joined = midnight(member.cohort_at)
            promotion = promoted.get(member.user_id)
            yield (
                member.user_id,
                day,
                "",
                joined,
                joined,
                joined if claimed else None,
                noon(member.deactivated_at) if gone else None,
                member.is_bot,
                member.is_admin or (promotion is not None and day >= promotion),
                False,
                False,
                member.is_restricted,
                member.is_ultra_restricted,
                not member.invite_pending,
                False,
                gone,
                member.invite_pending,
                stamped,
            )


def channel_rows(rng, channels, as_of, days=SNAPSHOT_DAYS):
    span = window(as_of, days)
    live = [channel for channel in channels if channel.date_created <= span[-1]]
    renamed = turns(rng, [c.channel_id for c in live], RENAME_SHARE, span)
    archived = turns(
        rng, [c.channel_id for c in live if not c.archived], ARCHIVE_SHARE, span
    )
    stamped = noon(as_of)
    for day in span:
        for channel in live:
            if channel.date_created > day:
                continue
            rename = renamed.get(channel.channel_id)
            shut = archived.get(channel.channel_id)
            yield (
                channel.channel_id,
                day,
                "",
                f"{channel.name}-v2" if rename is not None and day >= rename else channel.name,
                channel.visibility,
                channel.archived or (shut is not None and day >= shut),
                noon(channel.date_created),
                stamped,
            )


def rehash(conn):
    with conn.cursor() as cur:
        cur.execute(MEMBER_REHASH)
        members = cur.rowcount
        cur.execute(CHANNEL_REHASH)
        channels = cur.rowcount
    return members, channels
