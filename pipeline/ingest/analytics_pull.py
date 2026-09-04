import argparse
import gzip
import json
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timedelta, timezone

from dotenv import load_dotenv

from lib.db import (
    CHANNEL_DAY,
    MEMBER_DAY,
    connect,
    SyncCancelled,
    cancel_scope,
    current_cancel,
    current_step,
    dead_letter,
    ingest_run,
    mark_day_unavailable,
    record_day,
    run_step,
)
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from lib.walk import check_walk

ANALYTICS_SOURCE = "admin_analytics_api"
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

NEWER_DAY = """
        raw.member_dim.invite_flags_on IS NULL
        OR EXCLUDED.invite_flags_on >= raw.member_dim.invite_flags_on
"""

MEMBER_DIM_MERGE_SQL = f"""
INSERT INTO raw.member_dim
    (user_id, claimed_at, is_invited_member, is_invited_guest, invite_flags_on, updated_at)
VALUES (%s, %s, %s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    claimed_at = COALESCE(raw.member_dim.claimed_at, EXCLUDED.claimed_at),
    is_invited_member = CASE WHEN {NEWER_DAY}
        THEN EXCLUDED.is_invited_member ELSE raw.member_dim.is_invited_member END,
    is_invited_guest = CASE WHEN {NEWER_DAY}
        THEN EXCLUDED.is_invited_guest ELSE raw.member_dim.is_invited_guest END,
    invite_flags_on = greatest(raw.member_dim.invite_flags_on, EXCLUDED.invite_flags_on),
    updated_at = now()
"""

CHANNEL_ACTIVITY_SQL = """
INSERT INTO raw.channel_activity_snapshot
    (channel_id, window_start, window_end, source, messages_posted, messages_posted_by_members,
     members_who_posted, change_in_members_who_posted, members_who_viewed, reactions_added,
     members_who_reacted, huddles_initiated, total_members, full_members, guests)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (channel_id, window_start, window_end, source) DO UPDATE SET
    messages_posted = EXCLUDED.messages_posted,
    messages_posted_by_members = EXCLUDED.messages_posted_by_members,
    members_who_posted = EXCLUDED.members_who_posted,
    members_who_viewed = EXCLUDED.members_who_viewed,
    reactions_added = EXCLUDED.reactions_added,
    total_members = EXCLUDED.total_members,
    full_members = EXCLUDED.full_members,
    guests = EXCLUDED.guests
"""

CHANNEL_DIM_MERGE_SQL = """
INSERT INTO raw.channel_dim
    (channel_id, visibility, date_created, last_active_at, updated_at)
VALUES (%s, %s, %s, %s, now())
ON CONFLICT (channel_id) DO UPDATE SET
    visibility = COALESCE(EXCLUDED.visibility, raw.channel_dim.visibility),
    date_created = COALESCE(raw.channel_dim.date_created, EXCLUDED.date_created),
    last_active_at = greatest(raw.channel_dim.last_active_at, EXCLUDED.last_active_at),
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


def member_dim_row(rec, pull_date):
    return (
        rec["user_id"],
        parse_epoch(rec.get("date_claimed")),
        bool(rec.get("is_invited_member")),
        bool(rec.get("is_invited_guest")),
        pull_date,
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
        rec.get("total_members_count"),
        rec.get("full_members_count"),
        rec.get("guest_members_count"),
    )


def channel_dim_row(rec):
    return (
        rec["channel_id"],
        rec.get("visibility"),
        parse_epoch(rec.get("date_created")),
        parse_epoch(rec.get("date_last_active")),
    )


MEMBER_DAY_LIMIT = 6
CHANNEL_DAY_LIMIT = 30
DAY_WORKERS = int(os.environ.get("ANALYTICS_DAY_WORKERS", "") or 8)
CALENDAR_DAYS_MAX = 500


PERMANENT_DAY_ERRORS = ("file_not_found", "data_not_available")
PENDING_DAY_ERRORS = ("file_not_yet_available",)

DAY_TABLES = {
    "member": "raw.member_activity_snapshot",
    "channel": "raw.channel_activity_snapshot",
}


def settled_days(conn, source):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT ds FROM raw.analytics_day WHERE source = %s AND (loaded OR unavailable)",
            (source,),
        )
        return {row[0] for row in cur.fetchall()}


def calendar(client, kind):
    avail = client.call("admin.analytics.getAvailableDateRange", {"type": kind})
    return date.fromisoformat(avail["start_date"]), date.fromisoformat(avail["end_date"])


def pending_days(loaded, floor, edge, limit):
    missing, day = [], floor
    while day <= edge:
        if day not in loaded:
            missing.append(day)
        day += timedelta(days=1)
    if not missing or limit < 1:
        return []
    return missing[::-1][:limit]


def by_key(rows):
    return sorted(rows, key=lambda row: row[0])


def refresh_statistics(kind):
    table = DAY_TABLES.get(kind)
    if table is None:
        return
    refused = []
    try:
        with connect() as stats_conn:
            stats_conn.add_notice_handler(lambda note: refused.append(note.message_primary))
            stats_conn.execute(f"ANALYZE {table}")
    except Exception as exc:
        print(f"{table}: could not refresh statistics, {type(exc).__name__}: {exc}")
        return
    if refused:
        print(f"{table}: statistics NOT refreshed, {refused[0]}")
    else:
        print(f"{table}: statistics refreshed")


def note_unavailable(source, day, reason):
    try:
        with connect() as note_conn:
            mark_day_unavailable(note_conn, source, day, reason)
            note_conn.commit()
    except Exception as exc:
        print(f"{source}: {day} could not be marked unavailable, {type(exc).__name__}: {exc}")
        return False
    return True


def backfill_days(conn, source, kind, pull_fn, limit, workers=DAY_WORKERS):
    floor, edge = calendar(ProxyClient(), kind)
    days = pending_days(settled_days(conn, source), floor, edge, limit)
    conn.commit()
    if not days:
        print(f"{source}: every day in {floor}..{edge} is loaded")
        return

    step = current_step()
    cancel = current_cancel()
    lanes = max(1, min(workers, len(days)))
    print(f"{source}: {len(days)} unloaded day(s) of {floor}..{edge}, {lanes} at a time")

    def work(day):
        with connect() as worker_conn, run_step(*step), cancel_scope(cancel):
            pull_fn(worker_conn, day)

    failed, unavailable, pending = [], [], []
    with ThreadPoolExecutor(max_workers=lanes) as pool:
        submitted = {pool.submit(work, day): day for day in days}
        for future in as_completed(submitted):
            day = submitted[future]
            try:
                future.result()
            except SyncCancelled:
                raise
            except Exception as exc:
                if str(exc).startswith(PERMANENT_DAY_ERRORS):
                    if note_unavailable(source, day, str(exc)):
                        unavailable.append(str(day))
                    else:
                        failed.append(f"{day}: {type(exc).__name__}: {exc}")
                elif str(exc).startswith(PENDING_DAY_ERRORS):
                    pending.append(str(day))
                else:
                    failed.append(f"{day}: {type(exc).__name__}: {exc}")
    landed = len(days) - len(unavailable) - len(pending) - len(failed)
    if landed:
        refresh_statistics(kind)
    if unavailable:
        print(f"{source}: {len(unavailable)} day(s) have no export and will not be retried")
    if pending:
        print(f"{source}: {len(pending)} day(s) not exported yet, left for the next run")
    if failed:
        print(f"{source}: {len(failed)} of {len(days)} day(s) failed, left for the next run: "
              + "; ".join(failed))
    if failed and not landed:
        raise RuntimeError(f"{source}: no day landed, {len(failed)} failed: " + "; ".join(failed))


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
                cur.executemany(MEMBER_DIM_MERGE_SQL, by_key(dim_rows))
            conn.commit()
            activity_rows.clear()
            dim_rows.clear()
            counts.total_expected = client.last_num_found
            counts.progress()

        for i, rec in enumerate(client.paginate(
            "admin.analytics.getMemberAnalytics", params, "member_activity",
            page_size=MEMBER_PAGE_SIZE, cursor_param="cursor_mark", max_retries=8,
        )):
            counts.rows_in += 1
            try:
                activity_rows.append(member_activity_row(rec, pull_date))
                dim_rows.append(member_dim_row(rec, pull_date))
            except KeyError as exc:
                counts.rows_rejected += 1
                dead_letter(conn, ANALYTICS_SOURCE, rec, str(exc))
                conn.commit()
            if (i + 1) % 2000 == 0:
                flush()
        flush()

        check_walk(f"member analytics {pull_date}", counts.rows_in,
            client.last_num_found, MEMBER_PAGE_SIZE)

        record_day(conn, MEMBER_DAY, pull_date, counts.rows_in)
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
            cur.executemany(CHANNEL_DIM_MERGE_SQL, by_key(dim_rows))

        record_day(conn, CHANNEL_DAY, pull_date, counts.rows_in)
    print(f"channel analytics {pull_date}: {counts.rows_in} rows, {counts.rows_rejected} rejected")


DAY_WALKS = {
    "member": (MEMBER_DAY, pull_member_day),
    "channel": (CHANNEL_DAY, pull_channel_day),
}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="kind", required=True)

    for kind in DAY_WALKS:
        walk = sub.add_parser(kind)
        group = walk.add_mutually_exclusive_group(required=True)
        group.add_argument("--date", type=date.fromisoformat)
        group.add_argument("--backfill", action="store_true")
        walk.add_argument("--limit", type=int)
        walk.add_argument("--workers", type=int, default=DAY_WORKERS)

    args = parser.parse_args()
    load_dotenv(ENV_FILE)

    source, pull_fn = DAY_WALKS[args.kind]
    with connect() as conn:
        if args.backfill:
            backfill_days(
                conn, source, args.kind, pull_fn,
                args.limit or CALENDAR_DAYS_MAX,
                workers=args.workers,
            )
        else:
            pull_fn(conn, args.date)


if __name__ == "__main__":
    main()
