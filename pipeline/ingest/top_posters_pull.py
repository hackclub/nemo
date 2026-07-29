import argparse
import calendar
from datetime import date
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect, dead_letter, ingest_run
from lib.internal_client import InternalClient

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

SOURCE = "top_posters"
METHOD = "admin.analytics.getMemberAnalytics"
RANGE_METHOD = "admin.analytics.getAvailableDateRange"
TOP_N = 100

INSERT_SQL = """
INSERT INTO raw.top_posters_snapshot
    (window_start, window_end, user_id, display_name, messages_posted)
VALUES (%s, %s, %s, %s, %s)
ON CONFLICT (window_start, window_end, user_id) DO UPDATE SET
    display_name = EXCLUDED.display_name,
    messages_posted = EXCLUDED.messages_posted,
    pulled_at = now()
"""


def available_range(client):
    resp = client.call(RANGE_METHOD, {"type": "member"})
    rng = resp.get("available_date_range") or resp
    return date.fromisoformat(rng["start_date"]), date.fromisoformat(rng["end_date"])


def next_month(d):
    if d.month == 12:
        return d.replace(year=d.year + 1, month=1, day=1)
    return d.replace(month=d.month + 1, day=1)


def month_bounds(month, avail_start, avail_end):
    first = month.replace(day=1)
    last = first.replace(day=calendar.monthrange(first.year, first.month)[1])
    return max(first, avail_start), min(last, avail_end)


def months_in_range(avail_start, avail_end):
    months = []
    cur = avail_start.replace(day=1)
    end = avail_end.replace(day=1)
    while cur <= end:
        months.append(cur)
        cur = next_month(cur)
    return months


def top_posters_row(rec, window_start, window_end):
    return (
        window_start,
        window_end,
        rec["user_id"],
        rec.get("display_name"),
        rec.get("messages_posted"),
    )


def pull_month(conn, client, month, avail_start, avail_end):
    window_start, window_end = month_bounds(month, avail_start, avail_end)
    data = client.call(
        METHOD,
        {
            "start_date": window_start.isoformat(),
            "end_date": window_end.isoformat(),
            "count": TOP_N,
            "sort_column": "messages_posted",
            "sort_direction": "desc",
        },
    )

    rows = []
    rejected = 0
    for rec in data.get("member_activity") or []:
        if not rec.get("messages_posted"):
            continue
        try:
            rows.append(top_posters_row(rec, window_start, window_end))
        except KeyError as exc:
            rejected += 1
            dead_letter(conn, SOURCE, rec, str(exc))

    with conn.cursor() as cur:
        cur.executemany(INSERT_SQL, rows)
    conn.commit()
    return len(rows), rejected, window_start, window_end


def run(conn, month=None, backfill=False):
    with ingest_run(conn, SOURCE) as counts:
        client = InternalClient()
        avail_start, avail_end = available_range(client)

        if backfill:
            months = months_in_range(avail_start, avail_end)
        elif month:
            months = [month]
        else:
            months = [avail_end.replace(day=1)]

        for m in months:
            count, rejected, window_start, window_end = pull_month(
                conn, client, m, avail_start, avail_end
            )
            counts.rows_in += count
            counts.rows_rejected += rejected
            print(f"{SOURCE} {window_start}..{window_end}: {count} rows")

    print(f"{SOURCE}: {counts.rows_in} rows, {counts.rows_rejected} rejected across {len(months)} months")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--backfill", action="store_true")
    group.add_argument("--month", type=lambda s: date.fromisoformat(f"{s}-01"))
    args = parser.parse_args()

    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn, month=args.month, backfill=args.backfill)


if __name__ == "__main__":
    main()
