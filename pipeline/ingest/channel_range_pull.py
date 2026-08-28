import argparse
import os
from datetime import date, timedelta

from dotenv import load_dotenv

from lib.db import connect, dead_letter, get_walk, ingest_run, save_walk
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from lib.walk import check_walk

SOURCE = "admin_analytics_channel_range"
METHOD = "admin.analytics.getChannelAnalytics"
RANGE_METHOD = "admin.analytics.getAvailableDateRange"
PAGE_SIZE = 500
WINDOW_DAYS = 30

RANGE_SQL = """
INSERT INTO raw.channel_activity_snapshot
    (channel_id, window_start, window_end, source, messages_posted, messages_posted_by_members,
     members_who_posted, members_who_viewed, reactions_added, members_who_reacted,
     huddles_initiated, total_members, full_members, guests)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (channel_id, window_start, window_end, source) DO UPDATE SET
    messages_posted = EXCLUDED.messages_posted,
    messages_posted_by_members = EXCLUDED.messages_posted_by_members,
    members_who_posted = EXCLUDED.members_who_posted,
    members_who_viewed = EXCLUDED.members_who_viewed,
    reactions_added = EXCLUDED.reactions_added,
    members_who_reacted = EXCLUDED.members_who_reacted,
    huddles_initiated = EXCLUDED.huddles_initiated,
    total_members = EXCLUDED.total_members,
    full_members = EXCLUDED.full_members,
    guests = EXCLUDED.guests
"""

PRUNE_SQL = """
DELETE FROM raw.channel_activity_snapshot
WHERE source = %s AND (window_start, window_end) <> (%s, %s)
"""


def range_row(rec, start, end):
    return (
        rec["channel_id"],
        start,
        end,
        SOURCE,
        rec.get("messages_count"),
        rec.get("chats_count"),
        rec.get("writers_count"),
        rec.get("readers_count"),
        rec.get("reactions_count"),
        rec.get("users_who_reacted_count"),
        rec.get("huddles_count"),
        rec.get("total_members_count"),
        rec.get("full_members_count"),
        rec.get("guest_members_count"),
    )


def channel_calendar(client):
    resp = client.call(RANGE_METHOD, {"type": "channel"})
    rng = resp.get("available_date_range") or resp
    return date.fromisoformat(rng["start_date"]), date.fromisoformat(rng["end_date"])


def resolve_window(client, days=WINDOW_DAYS, end=None):
    floor, edge = channel_calendar(client)
    if end is None:
        end = edge
    return max(floor, end - timedelta(days=days - 1)), end


def run(conn, days=WINDOW_DAYS, end=None):
    client = ProxyClient()
    start, stop = resolve_window(client, days, end)
    params = {
        "start_date": start.isoformat(),
        "end_date": stop.isoformat(),
        "privacy": "public",
        "sort_column": "name",
        "sort_direction": "asc",
        "team_ids": os.environ.get("SLACK_TEAM_ID") or None,
    }
    window_key = f"{start}..{stop}"
    resume_at, already = get_walk(conn, SOURCE, window_key)

    with ingest_run(conn, SOURCE) as counts:
        counts.rows_in = already
        rows = []

        def flush(cursor, seen):
            with conn.cursor() as cur:
                cur.executemany(RANGE_SQL, rows)
            rows.clear()
            save_walk(conn, SOURCE, window_key, cursor, already + seen)
            counts.total_expected = client.last_num_found
            counts.progress()

        if resume_at:
            print(f"channel range {window_key}: resuming after {already} rows")

        for rec in client.paginate(
            METHOD,
            params,
            "channel_analytics",
            page_size=PAGE_SIZE,
            cursor_param="cursor_mark",
            max_retries=8,
            start_cursor=resume_at,
            on_page=flush,
        ):
            counts.rows_in += 1
            try:
                rows.append(range_row(rec, start, stop))
            except KeyError as exc:
                counts.rows_rejected += 1
                dead_letter(conn, SOURCE, {"keys": sorted(rec)}, str(exc))

        check_walk(f"channel range {window_key}", counts.rows_in,
            client.last_num_found, PAGE_SIZE)

        with conn.cursor() as cur:
            cur.executemany(RANGE_SQL, rows)
            cur.execute(PRUNE_SQL, (SOURCE, start, stop))
            pruned = cur.rowcount
        save_walk(conn, SOURCE, window_key, None, counts.rows_in)
    print(
        f"channel range {window_key}: {counts.rows_in} rows, "
        f"{counts.rows_rejected} rejected, {pruned} stale rows pruned"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=WINDOW_DAYS)
    parser.add_argument("--end", type=date.fromisoformat)
    args = parser.parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn, days=args.days, end=args.end)


if __name__ == "__main__":
    main()
