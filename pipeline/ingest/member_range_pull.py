import argparse
from datetime import date, timedelta
from pathlib import Path

from dotenv import load_dotenv

from ingest.analytics_pull import MEMBER_ACTIVITY_SQL, member_activity_row
from lib.db import connect, dead_letter, ingest_run
from lib.proxy_client import ProxyClient

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

SOURCE = "admin_analytics_member_range"
PAGE_SIZE = 500
FLUSH_EVERY = 2000

PRUNE_SQL = """
DELETE FROM raw.member_activity_snapshot
WHERE source = %s AND (window_start, window_end) <> (%s, %s)
"""


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
    with ingest_run(conn, SOURCE) as counts:
        rows = []

        def flush():
            with conn.cursor() as cur:
                cur.executemany(MEMBER_ACTIVITY_SQL, rows)
            rows.clear()

        for i, rec in enumerate(client.paginate(
            "admin.analytics.getMemberAnalytics", params, "member_activity",
            page_size=PAGE_SIZE, cursor_param="cursor_mark", max_retries=8,
        )):
            counts.rows_in += 1
            try:
                rows.append(member_activity_row(rec, start, stop, SOURCE))
            except KeyError as exc:
                counts.rows_rejected += 1
                dead_letter(conn, SOURCE, {"keys": sorted(rec)}, str(exc))
            if (i + 1) % FLUSH_EVERY == 0:
                flush()
        flush()

        expected = client.last_num_found
        if expected is not None and counts.rows_in > expected + PAGE_SIZE:
            raise RuntimeError(
                f"member range {start}..{stop}: walked {counts.rows_in} rows against a "
                f"num_found of {expected}, refusing to commit the window"
            )

        with conn.cursor() as cur:
            cur.execute(PRUNE_SQL, (SOURCE, start, stop))
            pruned = cur.rowcount
    print(
        f"member range {start}..{stop}: {counts.rows_in} rows, "
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
