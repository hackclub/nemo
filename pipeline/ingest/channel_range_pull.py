import argparse
import os
from datetime import date, datetime, timedelta, timezone

from dotenv import load_dotenv

from lib.db import connect, dead_letter, get_walk, ingest_run, save_walk
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from lib.walk import check_walk

SOURCE = "admin_analytics_channel_range"
SPAN_SOURCE = "admin_analytics_channel_span"
MONTH_SOURCE = "admin_analytics_channel_month"
METHOD = "admin.analytics.getChannelAnalytics"
RANGE_METHOD = "admin.analytics.getAvailableDateRange"
PAGE_SIZE = 500
WINDOW_DAYS = 30

RANGE_SQL = """
INSERT INTO raw.channel_activity_snapshot
    (channel_id, window_start, window_end, source, messages_posted, messages_posted_by_members,
     members_who_posted, members_who_viewed, reactions_added, members_who_reacted,
     huddles_initiated, total_members, full_members, guests,
     date_created, last_message_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
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
    guests = EXCLUDED.guests,
    date_created = EXCLUDED.date_created,
    last_message_at = EXCLUDED.last_message_at
"""

PRUNE_SQL = """
DELETE FROM raw.channel_activity_snapshot
WHERE source = %s AND (window_start, window_end) <> (%s, %s)
"""


def stamp(value):
    if value in (None, ""):
        return None
    try:
        seconds = int(value)
    except (TypeError, ValueError):
        return None
    if seconds <= 0:
        return None
    try:
        return datetime.fromtimestamp(seconds, tz=timezone.utc)
    except (OSError, OverflowError, ValueError):
        return None


def range_row(rec, start, end, source=SOURCE):
    return (
        rec["channel_id"],
        start,
        end,
        source,
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
        stamp(rec.get("date_create")),
        stamp(rec.get("last_message_posted")),
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


def span_window(client, end=None):
    floor, edge = channel_calendar(client)
    return floor, (end or edge)


def month_start(day):
    return day.replace(day=1)


def next_month(day):
    return date(day.year + day.month // 12, day.month % 12 + 1, 1)


def run(conn, days=WINDOW_DAYS, end=None, source=SOURCE, span=False):
    client = ProxyClient()
    start, stop = span_window(client, end) if span else resolve_window(client, days, end)
    params = {
        "start_date": start.isoformat(),
        "end_date": stop.isoformat(),
        "privacy": "public",
        "sort_column": "name",
        "sort_direction": "asc",
        "team_ids": os.environ.get("SLACK_TEAM_ID") or None,
    }
    window_key = f"{start}..{stop}"
    label = {SPAN_SOURCE: "channel span", MONTH_SOURCE: "channel month"}.get(
        source, "channel range"
    )
    resume_at, already = get_walk(conn, source, window_key)

    with ingest_run(conn, source) as counts:
        counts.rows_in = already
        rows = []

        def flush(cursor, seen):
            with conn.cursor() as cur:
                cur.executemany(RANGE_SQL, rows)
            rows.clear()
            save_walk(conn, source, window_key, cursor, already + seen)
            counts.total_expected = client.last_num_found
            counts.progress()

        if resume_at:
            print(f"{label} {window_key}: resuming after {already} rows")

        for rec in client.paginate(
            METHOD,
            params,
            "channel_analytics",
            page_size=PAGE_SIZE,
            cursor_param="cursor_mark",
            max_retries=8,
            start_cursor=resume_at,
            on_page=flush,
            allow_empty_pages=span,
        ):
            counts.rows_in += 1
            try:
                rows.append(range_row(rec, start, stop, source))
            except KeyError as exc:
                counts.rows_rejected += 1
                dead_letter(conn, source, {"keys": sorted(rec)}, str(exc))

        check_walk(f"{label} {window_key}", counts.rows_in,
            client.last_num_found, PAGE_SIZE)

        with conn.cursor() as cur:
            cur.executemany(RANGE_SQL, rows)
            cur.execute(PRUNE_SQL, (source, start, stop))
            pruned = cur.rowcount
        save_walk(conn, source, window_key, None, counts.rows_in)
    print(
        f"{label} {window_key}: {counts.rows_in} rows, "
        f"{counts.rows_rejected} rejected, {pruned} stale rows pruned"
    )
    return counts.rows_in


def run_span(conn, end=None):
    return run(conn, source=SPAN_SOURCE, span=True, end=end)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=WINDOW_DAYS)
    parser.add_argument("--end", type=date.fromisoformat)
    parser.add_argument("--span", action="store_true")
    args = parser.parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        if args.span:
            run_span(conn, end=args.end)
        else:
            run(conn, days=args.days, end=args.end)


if __name__ == "__main__":
    main()
