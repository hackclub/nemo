import argparse
import gzip
import json
from datetime import date, datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect, dead_letter, finish_run, get_cursor, save_cursor, start_run
from lib.slack_client import admin_client

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

ANALYTICS_SOURCE = "admin_analytics_api"
USERS_SOURCE = "admin_users_list"

MEMBER_ACTIVITY_SQL = """
INSERT INTO raw.member_activity_snapshot
    (user_id, window_start, window_end, source, days_active, days_active_desktop,
     days_active_android, days_active_ios, days_slack_connect, days_active_apps,
     days_active_workflows, messages_posted, channel_messages_posted, reactions_added,
     files_uploaded, huddles, searches, channels_joined, last_active_at,
     last_active_desktop_at, last_active_android_at, last_active_ios_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (user_id, window_start, window_end, source) DO UPDATE SET
    days_active = EXCLUDED.days_active,
    days_active_desktop = EXCLUDED.days_active_desktop,
    days_active_android = EXCLUDED.days_active_android,
    days_active_ios = EXCLUDED.days_active_ios,
    days_slack_connect = EXCLUDED.days_slack_connect,
    days_active_apps = EXCLUDED.days_active_apps,
    days_active_workflows = EXCLUDED.days_active_workflows,
    messages_posted = EXCLUDED.messages_posted,
    channel_messages_posted = EXCLUDED.channel_messages_posted,
    reactions_added = EXCLUDED.reactions_added,
    files_uploaded = EXCLUDED.files_uploaded,
    huddles = EXCLUDED.huddles,
    searches = EXCLUDED.searches
"""

MEMBER_DIM_MERGE_SQL = """
INSERT INTO raw.member_dim (user_id, is_guest, claimed_at, updated_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    is_guest = EXCLUDED.is_guest,
    claimed_at = COALESCE(raw.member_dim.claimed_at, EXCLUDED.claimed_at),
    updated_at = now()
"""

MEMBER_PROFILE_EMAIL_SQL = """
INSERT INTO moderation.member_profile (user_id, email, updated_at)
VALUES (%s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    email = EXCLUDED.email,
    updated_at = now()
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
    members_who_viewed = EXCLUDED.members_who_viewed,
    reactions_added = EXCLUDED.reactions_added
"""

CHANNEL_DIM_MERGE_SQL = """
INSERT INTO raw.channel_dim
    (channel_id, visibility, total_members, full_members, guests, date_created, last_active_at, updated_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, now())
ON CONFLICT (channel_id) DO UPDATE SET
    visibility = COALESCE(EXCLUDED.visibility, raw.channel_dim.visibility),
    total_members = EXCLUDED.total_members,
    full_members = EXCLUDED.full_members,
    guests = EXCLUDED.guests,
    date_created = COALESCE(raw.channel_dim.date_created, EXCLUDED.date_created),
    last_active_at = EXCLUDED.last_active_at,
    updated_at = now()
"""

USER_DIM_MERGE_SQL = """
INSERT INTO raw.member_dim (user_id, account_created, deactivated_at, updated_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    account_created = EXCLUDED.account_created,
    deactivated_at = EXCLUDED.deactivated_at,
    updated_at = now()
"""

USER_PROFILE_SQL = """
INSERT INTO moderation.member_profile (user_id, name, username, email, updated_at)
VALUES (%s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    name = COALESCE(EXCLUDED.name, moderation.member_profile.name),
    username = COALESCE(EXCLUDED.username, moderation.member_profile.username),
    email = COALESCE(EXCLUDED.email, moderation.member_profile.email),
    updated_at = now()
"""


def parse_epoch(value):
    if not value:
        return None
    return datetime.fromtimestamp(int(value), tz=timezone.utc)


def fetch_ndjson(resp):
    body = gzip.decompress(resp.data)
    for line in body.decode("utf-8").splitlines():
        line = line.strip()
        if line:
            yield line


def member_activity_row(rec, pull_date):
    return (
        rec["user_id"],
        pull_date,
        pull_date,
        ANALYTICS_SOURCE,
        int(bool(rec.get("is_active"))),
        int(bool(rec.get("is_active_desktop"))),
        int(bool(rec.get("is_active_android"))),
        int(bool(rec.get("is_active_ios"))),
        int(bool(rec.get("is_active_slack_connect"))),
        int(bool(rec.get("is_active_apps"))),
        int(bool(rec.get("is_active_workflows"))),
        rec.get("messages_posted_count"),
        rec.get("channel_messages_posted_count"),
        rec.get("reactions_added_count"),
        rec.get("files_added_count"),
        rec.get("slack_huddles_count"),
        rec.get("search_count"),
        None,
        None,
        None,
        None,
        None,
    )


def member_dim_row(rec):
    return (rec["user_id"], bool(rec.get("is_guest")), parse_epoch(rec.get("date_claimed")))


def member_profile_row(rec):
    email = rec.get("email_address")
    if not email:
        return None
    return (rec["user_id"], email)


def channel_activity_row(rec, pull_date):
    return (
        rec["channel_id"],
        pull_date,
        pull_date,
        ANALYTICS_SOURCE,
        rec.get("messages_posted_count"),
        rec.get("messages_posted_by_members_count"),
        rec.get("members_who_posted_count"),
        None,
        rec.get("members_who_viewed_count"),
        rec.get("reactions_added_count"),
        None,
        None,
    )


def channel_dim_row(rec):
    return (
        rec["channel_id"],
        rec.get("visibility"),
        rec.get("total_members_count"),
        rec.get("full_members_count"),
        rec.get("guest_member_count"),
        parse_epoch(rec.get("date_created")),
        parse_epoch(rec.get("date_last_active")),
    )


def user_dim_row(user):
    return (user["id"], parse_epoch(user.get("date_created")), parse_epoch(user.get("deactivated_ts")))


def user_profile_row(user):
    return (user["id"], user.get("full_name"), user.get("username"), user.get("email"))


def pull_member_day(conn, pull_date):
    run_id = start_run(conn, f"{ANALYTICS_SOURCE}:member")
    rows_in = rows_rejected = 0
    activity_rows, dim_rows, profile_rows = [], [], []
    resp = admin_client().admin_analytics_getFile(type="member", date=pull_date.isoformat())
    for line in fetch_ndjson(resp):
        rows_in += 1
        try:
            rec = json.loads(line)
            activity_rows.append(member_activity_row(rec, pull_date))
            dim_rows.append(member_dim_row(rec))
            profile_row = member_profile_row(rec)
            if profile_row:
                profile_rows.append(profile_row)
        except (json.JSONDecodeError, KeyError) as exc:
            rows_rejected += 1
            dead_letter(conn, ANALYTICS_SOURCE, {"raw_line": line}, str(exc))
    with conn.cursor() as cur:
        cur.executemany(MEMBER_ACTIVITY_SQL, activity_rows)
        cur.executemany(MEMBER_DIM_MERGE_SQL, dim_rows)
        cur.executemany(MEMBER_PROFILE_EMAIL_SQL, profile_rows)
    finish_run(conn, run_id, "ok", rows_in, rows_rejected)
    print(f"member analytics {pull_date}: {rows_in} rows, {rows_rejected} rejected")


def pull_channel_day(conn, pull_date):
    run_id = start_run(conn, f"{ANALYTICS_SOURCE}:public_channel")
    rows_in = rows_rejected = 0
    activity_rows, dim_rows = [], []
    resp = admin_client().admin_analytics_getFile(type="public_channel", date=pull_date.isoformat())
    for line in fetch_ndjson(resp):
        rows_in += 1
        try:
            rec = json.loads(line)
            activity_rows.append(channel_activity_row(rec, pull_date))
            dim_rows.append(channel_dim_row(rec))
        except (json.JSONDecodeError, KeyError) as exc:
            rows_rejected += 1
            dead_letter(conn, ANALYTICS_SOURCE, {"raw_line": line}, str(exc))
    with conn.cursor() as cur:
        cur.executemany(CHANNEL_ACTIVITY_SQL, activity_rows)
        cur.executemany(CHANNEL_DIM_MERGE_SQL, dim_rows)
    finish_run(conn, run_id, "ok", rows_in, rows_rejected)
    print(f"channel analytics {pull_date}: {rows_in} rows, {rows_rejected} rejected")


def pull_users(conn):
    run_id = start_run(conn, USERS_SOURCE)
    rows_in = rows_rejected = 0
    cursor = get_cursor(conn, USERS_SOURCE)
    while True:
        page = admin_client().admin_users_list(limit=99, cursor=cursor)
        dim_rows, profile_rows = [], []
        for user in page.get("users", []):
            rows_in += 1
            try:
                dim_rows.append(user_dim_row(user))
                profile_rows.append(user_profile_row(user))
            except KeyError as exc:
                rows_rejected += 1
                dead_letter(conn, USERS_SOURCE, user, str(exc))
        with conn.cursor() as cur:
            cur.executemany(USER_DIM_MERGE_SQL, dim_rows)
            cur.executemany(USER_PROFILE_SQL, profile_rows)
        cursor = page.get("response_metadata", {}).get("next_cursor") or ""
        save_cursor(conn, USERS_SOURCE, cursor)
        conn.commit()
        if not cursor:
            break
    finish_run(conn, run_id, "ok", rows_in, rows_rejected)
    conn.commit()
    print(f"admin users: {rows_in} rows, {rows_rejected} rejected")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="kind", required=True)

    member = sub.add_parser("member")
    member.add_argument("--date", required=True, type=date.fromisoformat)

    channel = sub.add_parser("channel")
    channel.add_argument("--date", required=True, type=date.fromisoformat)

    sub.add_parser("users")

    args = parser.parse_args()
    load_dotenv(ENV_FILE)

    with connect() as conn:
        if args.kind == "member":
            pull_member_day(conn, args.date)
        elif args.kind == "channel":
            pull_channel_day(conn, args.date)
        else:
            pull_users(conn)


if __name__ == "__main__":
    main()
