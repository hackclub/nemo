import argparse
from datetime import date, timedelta

from dotenv import load_dotenv

from ingest.analytics_pull import MEMBER_ACTIVITY_SQL, member_activity_row, parse_epoch
from lib.db import connect, dead_letter, get_walk, ingest_run, save_walk
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from lib.walk import check_walk

SOURCE = "admin_analytics_member_range"
PAGE_SIZE = 500

PRUNE_SQL = """
DELETE FROM raw.member_activity_snapshot
WHERE source = %s AND (window_start, window_end) <> (%s, %s)
"""

VERIFIED_DATE_SQL = """
INSERT INTO raw.member_dim
    (user_id, account_created_verified, claimed_at, updated_at)
VALUES (%s, %s, %s, now())
ON CONFLICT (user_id) DO UPDATE SET
    account_created_verified = EXCLUDED.account_created_verified,
    claimed_at = COALESCE(raw.member_dim.claimed_at, EXCLUDED.claimed_at),
    updated_at = now()
"""


def verified_date_row(rec):
    return (
        rec["user_id"],
        parse_epoch(rec.get("date_created")),
        parse_epoch(rec.get("date_claimed")),
    )


def resolve_window(client, days=None, end=None):
    avail = client.call("admin.analytics.getAvailableDateRange", {"type": "member"})
    floor = date.fromisoformat(avail["start_date"])
    if end is None:
        end = date.fromisoformat(avail["end_date"])
    if days is None:
        return floor, end
    return max(floor, end - timedelta(days=days - 1)), end


def run(conn, days=None, end=None):
    client = ProxyClient()
    start, stop = resolve_window(client, days, end)
    params = {
        "start_date": start.isoformat(),
        "end_date": stop.isoformat(),
        "sort_column": "username",
        "sort_direction": "asc",
    }
    window_key = f"{start}..{stop}"
    resume_at, already = get_walk(conn, SOURCE, window_key)

    with ingest_run(conn, SOURCE) as counts:
        counts.rows_in = already
        rows, dates = [], []
        dates_written = 0

        def flush(cursor, seen):
            nonlocal dates_written
            with conn.cursor() as cur:
                cur.executemany(MEMBER_ACTIVITY_SQL, rows)
                cur.executemany(VERIFIED_DATE_SQL, dates)
            dates_written += len(dates)
            rows.clear()
            dates.clear()
            save_walk(conn, SOURCE, window_key, cursor, already + seen)
            counts.total_expected = client.last_num_found
            counts.progress()

        if resume_at:
            print(f"member range {window_key}: resuming after {already} rows")

        for rec in client.paginate(
            "admin.analytics.getMemberAnalytics", params, "member_activity",
            page_size=PAGE_SIZE, cursor_param="cursor_mark", max_retries=8,
            start_cursor=resume_at, on_page=flush,
        ):
            counts.rows_in += 1
            try:
                rows.append(member_activity_row(rec, start, stop, SOURCE))
                dates.append(verified_date_row(rec))
            except KeyError as exc:
                counts.rows_rejected += 1
                dead_letter(conn, SOURCE, {"keys": sorted(rec)}, str(exc))

        check_walk(f"member range {window_key}", counts.rows_in,
            client.last_num_found, PAGE_SIZE)

        with conn.cursor() as cur:
            cur.execute(PRUNE_SQL, (SOURCE, start, stop))
            pruned = cur.rowcount
        save_walk(conn, SOURCE, window_key, None, counts.rows_in)
    print(
        f"member range {window_key}: {counts.rows_in} rows, {dates_written} dates, "
        f"{counts.rows_rejected} rejected, {pruned} stale rows pruned"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int)
    parser.add_argument("--end", type=date.fromisoformat)
    args = parser.parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn, days=args.days, end=args.end)


if __name__ == "__main__":
    main()
