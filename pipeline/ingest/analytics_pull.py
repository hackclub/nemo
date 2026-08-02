import argparse
import gzip
import json
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect, dead_letter, get_cursor, ingest_run, save_cursor
from lib.proxy_client import InternalAuthError, ProxyClient, ProxyError

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

ANALYTICS_SOURCE = "admin_analytics_api"
USERS_SOURCE = "admin_users_list"
MEMBER_PAGE_SIZE = 500

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
INSERT INTO raw.member_dim
    (user_id, claimed_at, is_invited_member, is_invited_guest, updated_at)
VALUES (%s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    claimed_at = COALESCE(raw.member_dim.claimed_at, EXCLUDED.claimed_at),
    is_invited_member = EXCLUDED.is_invited_member,
    is_invited_guest = EXCLUDED.is_invited_guest,
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


def fetch_ndjson(raw):
    body = gzip.decompress(raw)
    for line in body.decode("utf-8").splitlines():
        line = line.strip()
        if line:
            yield line


def member_activity_row(rec, start, end=None, source=ANALYTICS_SOURCE):
    return (
        rec["user_id"],
        start,
        end or start,
        source,
        rec.get("days_active"),
        rec.get("days_active_desktop"),
        rec.get("days_active_android"),
        rec.get("days_active_ios"),
        rec.get("days_active_slack_connect"),
        None,
        None,
        rec.get("messages_posted"),
        rec.get("messages_posted_in_channel"),
        rec.get("reactions_added"),
        rec.get("files_added_count"),
        rec.get("slack_huddles_count"),
        rec.get("search_count"),
        rec.get("channels_joined_count"),
        parse_epoch(rec.get("date_last_active")),
        parse_epoch(rec.get("date_last_active_desktop")),
        parse_epoch(rec.get("date_last_active_android")),
        parse_epoch(rec.get("date_last_active_ios")),
    )


def member_dim_row(rec):
    return (
        rec["user_id"],
        parse_epoch(rec.get("date_claimed")),
        bool(rec.get("is_invited_member")),
        bool(rec.get("is_invited_guest")),
    )


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
        rec.get("guest_members_count"),
        parse_epoch(rec.get("date_created")),
        parse_epoch(rec.get("date_last_active")),
    )


def user_dim_row(user):
    return (
        user["id"],
        parse_epoch(user.get("date_created")),
        parse_epoch(user.get("deactivated_ts")),
    )


def user_profile_row(user):
    return (user["id"], user.get("full_name"), user.get("username"), user.get("email"))


def backfill(conn, pull_fn, label):
    avail = ProxyClient().call("admin.analytics.getAvailableDateRange", {"type": "member"})
    pull_date = date.fromisoformat(avail["end_date"])
    end_date = date.fromisoformat(avail["start_date"])
    print(f"{label} backfill: {end_date} .. {pull_date}")
    while pull_date >= end_date:
        try:
            pull_fn(conn, pull_date)
            conn.commit()
        except (InternalAuthError, ProxyError):
            conn.rollback()
            raise
        except Exception as exc:
            conn.rollback()
            dead_letter(conn, f"{label}_backfill", {"date": pull_date.isoformat()}, str(exc))
            conn.commit()
            print(f"{label} backfill {pull_date}: ERROR {exc}")
        pull_date -= timedelta(days=1)


def pull_member_day(conn, pull_date):
    with ingest_run(conn, f"{ANALYTICS_SOURCE}:member") as counts:
        activity_rows, dim_rows = [], []
        client = ProxyClient()
        params = {
            "start_date": pull_date.isoformat(),
            "end_date": pull_date.isoformat(),
            "sort_column": "real_name",
            "sort_direction": "asc",
        }

        def flush():
            with conn.cursor() as cur:
                cur.executemany(MEMBER_ACTIVITY_SQL, activity_rows)
                cur.executemany(MEMBER_DIM_MERGE_SQL, dim_rows)
            activity_rows.clear()
            dim_rows.clear()

        for i, rec in enumerate(client.paginate(
            "admin.analytics.getMemberAnalytics", params, "member_activity",
            page_size=MEMBER_PAGE_SIZE, cursor_param="cursor_mark", max_retries=8,
        )):
            counts.rows_in += 1
            try:
                activity_rows.append(member_activity_row(rec, pull_date))
                dim_rows.append(member_dim_row(rec))
            except KeyError as exc:
                counts.rows_rejected += 1
                dead_letter(conn, ANALYTICS_SOURCE, rec, str(exc))
            if (i + 1) % 2000 == 0:
                flush()
        flush()

        expected = client.last_num_found
        if expected is not None and counts.rows_in > expected + MEMBER_PAGE_SIZE:
            raise RuntimeError(
                f"member analytics {pull_date}: walked {counts.rows_in} rows against a "
                f"num_found of {expected}, refusing to commit the day"
            )
    print(f"member analytics {pull_date}: {counts.rows_in} rows, {counts.rows_rejected} rejected")


def pull_channel_day(conn, pull_date):
    with ingest_run(conn, f"{ANALYTICS_SOURCE}:public_channel") as counts:
        activity_rows, dim_rows = [], []
        raw = ProxyClient().fetch_file(
            "admin.analytics.getFile",
            {"type": "public_channel", "date": pull_date.isoformat()},
        )
        for line in fetch_ndjson(raw):
            counts.rows_in += 1
            try:
                rec = json.loads(line)
                activity_rows.append(channel_activity_row(rec, pull_date))
                dim_rows.append(channel_dim_row(rec))
            except (json.JSONDecodeError, KeyError) as exc:
                counts.rows_rejected += 1
                dead_letter(conn, ANALYTICS_SOURCE, {"raw_line": line}, str(exc))
        with conn.cursor() as cur:
            cur.executemany(CHANNEL_ACTIVITY_SQL, activity_rows)
            cur.executemany(CHANNEL_DIM_MERGE_SQL, dim_rows)
    print(f"channel analytics {pull_date}: {counts.rows_in} rows, {counts.rows_rejected} rejected")


def pull_users_page(conn, is_active):
    label = "active" if is_active else "deactivated"
    with ingest_run(conn, f"{USERS_SOURCE}:{label}") as counts:
        cursor = get_cursor(conn, USERS_SOURCE, channel_id=label)
        client = ProxyClient()
        while True:
            page = client.call(
                "admin.users.list",
                {"limit": 99, "cursor": cursor, "is_active": is_active},
                credential="admin",
            )
            dim_rows, profile_rows = [], []
            for user in page.get("users", []):
                counts.rows_in += 1
                try:
                    dim_rows.append(user_dim_row(user))
                    profile_rows.append(user_profile_row(user))
                except KeyError as exc:
                    counts.rows_rejected += 1
                    dead_letter(conn, USERS_SOURCE, user, str(exc))
            with conn.cursor() as cur:
                cur.executemany(USER_DIM_MERGE_SQL, dim_rows)
                cur.executemany(USER_PROFILE_SQL, profile_rows)
            cursor = page.get("response_metadata", {}).get("next_cursor") or ""
            save_cursor(conn, USERS_SOURCE, cursor, channel_id=label)
            conn.commit()
            if not cursor:
                break
    print(f"admin users ({label}): {counts.rows_in} rows, {counts.rows_rejected} rejected")


def pull_users(conn):
    pull_users_page(conn, is_active=True)
    pull_users_page(conn, is_active=False)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="kind", required=True)

    member = sub.add_parser("member")
    member_group = member.add_mutually_exclusive_group(required=True)
    member_group.add_argument("--date", type=date.fromisoformat)
    member_group.add_argument("--backfill", action="store_true")

    channel = sub.add_parser("channel")
    channel_group = channel.add_mutually_exclusive_group(required=True)
    channel_group.add_argument("--date", type=date.fromisoformat)
    channel_group.add_argument("--backfill", action="store_true")

    sub.add_parser("users")

    args = parser.parse_args()
    load_dotenv(ENV_FILE)

    with connect() as conn:
        if args.kind == "member":
            if args.backfill:
                backfill(conn, pull_member_day, "member")
            else:
                pull_member_day(conn, args.date)
        elif args.kind == "channel":
            if args.backfill:
                backfill(conn, pull_channel_day, "channel")
            else:
                pull_channel_day(conn, args.date)
        else:
            pull_users(conn)


if __name__ == "__main__":
    main()
