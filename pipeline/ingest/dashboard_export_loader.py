import argparse
import csv
from datetime import date, datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

MEMBER_SOURCE = "dashboard_member"
CHANNEL_SOURCE = "dashboard_channel"

TRUTHY = {"true", "yes", "1", "t", "y"}


def parse_int(value):
    value = (value or "").strip()
    return int(value) if value else None


def parse_bool(value):
    return (value or "").strip().lower() in TRUTHY


def parse_short_date(value):
    value = (value or "").strip()
    if not value:
        return None
    return datetime.strptime(value, "%b %d, %Y").replace(tzinfo=timezone.utc)


def parse_rfc_date(value):
    value = (value or "").strip()
    return parsedate_to_datetime(value) if value else None


def read_rows(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        yield from csv.DictReader(fh)


MEMBER_DIM_SQL = """
INSERT INTO raw.member_dim
    (user_id, account_type, is_guest, account_created, claimed_at, deactivated_at, updated_at)
VALUES (%s, %s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    account_type = EXCLUDED.account_type,
    is_guest = EXCLUDED.is_guest,
    account_created = EXCLUDED.account_created,
    claimed_at = EXCLUDED.claimed_at,
    deactivated_at = EXCLUDED.deactivated_at,
    updated_at = now()
"""

MEMBER_ACTIVITY_SQL = """
INSERT INTO raw.member_activity_snapshot
    (user_id, window_start, window_end, source, days_active, days_active_desktop,
     days_active_android, days_active_ios, days_slack_connect, messages_posted,
     channel_messages_posted, reactions_added, files_uploaded, huddles, searches,
     channels_joined, last_active_at, last_active_desktop_at, last_active_android_at,
     last_active_ios_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (user_id, window_start, window_end, source) DO UPDATE SET
    days_active = EXCLUDED.days_active,
    days_active_desktop = EXCLUDED.days_active_desktop,
    days_active_android = EXCLUDED.days_active_android,
    days_active_ios = EXCLUDED.days_active_ios,
    days_slack_connect = EXCLUDED.days_slack_connect,
    messages_posted = EXCLUDED.messages_posted,
    channel_messages_posted = EXCLUDED.channel_messages_posted,
    reactions_added = EXCLUDED.reactions_added,
    files_uploaded = EXCLUDED.files_uploaded,
    huddles = EXCLUDED.huddles,
    searches = EXCLUDED.searches,
    channels_joined = EXCLUDED.channels_joined,
    last_active_at = EXCLUDED.last_active_at,
    last_active_desktop_at = EXCLUDED.last_active_desktop_at,
    last_active_android_at = EXCLUDED.last_active_android_at,
    last_active_ios_at = EXCLUDED.last_active_ios_at
"""

MEMBER_PROFILE_SQL = """
INSERT INTO moderation.member_profile
    (user_id, name, display_name, username, email, claimed_at, updated_at)
VALUES (%s, %s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    name = EXCLUDED.name,
    display_name = EXCLUDED.display_name,
    username = EXCLUDED.username,
    email = EXCLUDED.email,
    claimed_at = EXCLUDED.claimed_at,
    updated_at = now()
"""

SLACK_MEMBER_PROFILE_SQL = """
INSERT INTO moderation.member_profile
    (user_id, name, display_name, username, email, updated_at)
VALUES (%s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    name = EXCLUDED.name,
    display_name = COALESCE(EXCLUDED.display_name, moderation.member_profile.display_name),
    username = EXCLUDED.username,
    email = EXCLUDED.email,
    updated_at = now()
"""

CHANNEL_DIM_SQL = """
INSERT INTO raw.channel_dim
    (channel_id, name, visibility, archived, date_created, last_active_at, creator_id, total_members, updated_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (channel_id) DO UPDATE SET
    name = EXCLUDED.name,
    visibility = EXCLUDED.visibility,
    archived = EXCLUDED.archived,
    date_created = EXCLUDED.date_created,
    last_active_at = EXCLUDED.last_active_at,
    creator_id = EXCLUDED.creator_id,
    total_members = EXCLUDED.total_members,
    updated_at = now()
"""

CHANNEL_MEMBERSHIP_SQL = """
UPDATE raw.channel_dim SET full_members = %s, guests = %s, updated_at = now()
WHERE channel_id = %s
"""

CHANNEL_ACTIVITY_SQL = """
INSERT INTO raw.channel_activity_snapshot
    (channel_id, window_start, window_end, source, messages_posted, messages_posted_by_members,
     members_who_posted, change_in_members_who_posted, members_who_viewed, reactions_added,
     members_who_reacted, huddles_initiated)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (channel_id, window_start, window_end, source) DO UPDATE SET
    messages_posted = EXCLUDED.messages_posted,
    messages_posted_by_members = EXCLUDED.messages_posted_by_members,
    members_who_posted = EXCLUDED.members_who_posted,
    change_in_members_who_posted = EXCLUDED.change_in_members_who_posted,
    members_who_viewed = EXCLUDED.members_who_viewed,
    reactions_added = EXCLUDED.reactions_added,
    members_who_reacted = EXCLUDED.members_who_reacted,
    huddles_initiated = EXCLUDED.huddles_initiated
"""


def load_members(conn, files, window_start, window_end, with_pii=False):
    dim_rows = []
    activity_rows = []
    pii_rows = []
    for path in files:
        for row in read_rows(path):
            user_id = (row.get("User ID") or "").strip()
            if not user_id:
                continue
            account_type = (row.get("Account type") or "").strip()
            dim_rows.append((
                user_id,
                account_type,
                "guest" in account_type.lower(),
                parse_short_date(row.get("Account created (UTC)")),
                parse_short_date(row.get("Claimed Date (UTC)")),
                parse_short_date(row.get("Deactivated date (UTC)")),
            ))
            if with_pii:
                pii_rows.append((
                    user_id,
                    (row.get("Name") or "").strip() or None,
                    (row.get("Display name") or "").strip() or None,
                    (row.get("Username") or "").strip() or None,
                    (row.get("Email") or "").strip() or None,
                    parse_short_date(row.get("Claimed Date (UTC)")),
                ))
            activity_rows.append((
                user_id,
                window_start,
                window_end,
                MEMBER_SOURCE,
                parse_int(row.get("Days active")),
                parse_int(row.get("Days active (Desktop)")),
                parse_int(row.get("Days active (Android)")),
                parse_int(row.get("Days active (iOS)")),
                parse_int(row.get("Days using Slack Connect")),
                parse_int(row.get("Messages posted")),
                parse_int(row.get("Messages posted in channels")),
                parse_int(row.get("Reactions added")),
                parse_int(row.get("Files uploaded")),
                parse_int(row.get("Slack Huddles")),
                parse_int(row.get("Searches")),
                parse_int(row.get("Channels joined")),
                parse_short_date(row.get("Last active (UTC)")),
                parse_short_date(row.get("Last active (Desktop) (UTC)")),
                parse_short_date(row.get("Last active (Android) (UTC)")),
                parse_short_date(row.get("Last active (iOS) (UTC)")),
            ))
    with conn.cursor() as cur:
        cur.executemany(MEMBER_DIM_SQL, dim_rows)
        cur.executemany(MEMBER_ACTIVITY_SQL, activity_rows)
        if pii_rows:
            cur.executemany(MEMBER_PROFILE_SQL, pii_rows)
    msg = f"members: {len(dim_rows)} dim rows, {len(activity_rows)} activity rows"
    if with_pii:
        msg += f", {len(pii_rows)} pii profiles into moderation"
    print(msg)


def load_slack_members(conn, files):
    rows = []
    for path in files:
        for row in read_rows(path):
            user_id = (row.get("userid") or "").strip()
            if not user_id:
                continue
            rows.append((
                user_id,
                (row.get("fullname") or "").strip() or None,
                (row.get("displayname") or "").strip() or None,
                (row.get("username") or "").strip() or None,
                (row.get("email") or "").strip() or None,
            ))
    with conn.cursor() as cur:
        cur.executemany(SLACK_MEMBER_PROFILE_SQL, rows)
    print(f"slack-members: {len(rows)} pii profiles upserted into moderation")


def load_channels(conn, analytics_files, admin_file, window_start, window_end):
    name_to_id = {}
    dim_rows = []
    for row in read_rows(admin_file):
        channel_id = (row.get("ID") or "").strip()
        name = (row.get("Name") or "").strip()
        if not channel_id:
            continue
        name_to_id[name] = channel_id
        dim_rows.append((
            channel_id,
            name,
            "private" if parse_bool(row.get("Private")) else "public",
            parse_bool(row.get("Archived")),
            parse_rfc_date(row.get("Creation date")),
            parse_rfc_date(row.get("Last activity")),
            (row.get("Creator ID") or "").strip() or None,
            parse_int(row.get("Members")),
        ))

    activity_rows = []
    membership_rows = []
    skipped = 0
    for path in analytics_files:
        for row in read_rows(path):
            name = (row.get("Name") or "").strip()
            channel_id = name_to_id.get(name)
            if channel_id is None:
                skipped += 1
                continue
            activity_rows.append((
                channel_id,
                window_start,
                window_end,
                CHANNEL_SOURCE,
                parse_int(row.get("Messages posted")),
                parse_int(row.get("Messages posted by members")),
                parse_int(row.get("Members who posted")),
                parse_int(row.get("Change in members who posted")),
                parse_int(row.get("Members who viewed")),
                parse_int(row.get("Reactions added")),
                parse_int(row.get("Members who reacted")),
                parse_int(row.get("Huddles initiated")),
            ))
            membership_rows.append((
                parse_int(row.get("Full Members")),
                parse_int(row.get("Guests")),
                channel_id,
            ))

    with conn.cursor() as cur:
        cur.executemany(CHANNEL_DIM_SQL, dim_rows)
        cur.executemany(CHANNEL_ACTIVITY_SQL, activity_rows)
        cur.executemany(CHANNEL_MEMBERSHIP_SQL, membership_rows)
    print(f"channels: {len(dim_rows)} dim rows, {len(activity_rows)} activity rows, {skipped} skipped (name not in admin export)")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="kind", required=True)

    member = sub.add_parser("member")
    member.add_argument("--window-start", required=True, type=date.fromisoformat)
    member.add_argument("--window-end", required=True, type=date.fromisoformat)
    member.add_argument("--with-pii", action="store_true")
    member.add_argument("files", nargs="+", type=Path)

    channel = sub.add_parser("channel")
    channel.add_argument("--window-start", required=True, type=date.fromisoformat)
    channel.add_argument("--window-end", required=True, type=date.fromisoformat)
    channel.add_argument("--admin", required=True, type=Path)
    channel.add_argument("files", nargs="+", type=Path)

    slack_members = sub.add_parser("slack-members")
    slack_members.add_argument("files", nargs="+", type=Path)

    args = parser.parse_args()
    load_dotenv(ENV_FILE)

    with connect() as conn:
        if args.kind == "member":
            load_members(conn, args.files, args.window_start, args.window_end, args.with_pii)
        elif args.kind == "channel":
            load_channels(conn, args.files, args.admin, args.window_start, args.window_end)
        else:
            load_slack_members(conn, args.files)


if __name__ == "__main__":
    main()
