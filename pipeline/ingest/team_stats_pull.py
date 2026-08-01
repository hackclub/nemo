import argparse
from datetime import date, timedelta
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect, dead_letter, ingest_run
from lib.proxy_client import ProxyClient

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

SOURCE = "team_stats"
METHOD = "team.stats.timeSeries"
RANGE_METHOD = "admin.analytics.getAvailableDateRange"
MAX_WINDOW_DAYS = 380

FIELDS = (
    "total_members_count",
    "total_claimed_count",
    "full_members_count",
    "guests_count",
    "claimed_full_members_count",
    "claimed_guests_count",
    "total_full_members_count",
    "total_guests_count",
    "active_users_1d",
    "active_users_7d",
    "active_users_28d",
    "writers_count_1d",
    "writers_count_7d",
    "writers_count_28d",
    "readers_count_1d",
    "readers_count_7d",
    "messages_count_1d",
    "messages_channels_count_from_apps_1d",
    "chats_count_1d",
    "chats_channels_count_1d",
    "chats_groups_count_1d",
    "chats_dms_count_1d",
    "chats_shared_channels_count_1d",
    "cursor_marks_channels_count_1d",
    "cursor_marks_groups_count_1d",
    "cursor_marks_dms_count_1d",
    "cursor_marks_shared_channels_count_1d",
    "files_count_1d",
    "files_size",
    "channels_count",
    "users_channels_count",
)

INSERT_SQL = f"""
INSERT INTO raw.team_stats_snapshot (ds, source, {", ".join(FIELDS)})
VALUES (%s, %s, {", ".join(["%s"] * len(FIELDS))})
ON CONFLICT (ds) DO UPDATE SET
    {", ".join(f"{f} = EXCLUDED.{f}" for f in FIELDS)},
    pulled_at = now()
"""


def team_stats_row(rec):
    return (rec["ds"], SOURCE, *(rec.get(f) for f in FIELDS))


def probe_date(client):
    hint = client.call(RANGE_METHOD, {"type": "member"})
    rng = hint.get("available_date_range") or hint
    first = date.fromisoformat(rng["start_date"])
    last = date.fromisoformat(rng["end_date"])
    return first + (last - first) // 2


def available_range(client):
    probe = probe_date(client).isoformat()
    resp = client.call(METHOD, {"start_date": probe, "end_date": probe})
    rng = resp.get("available_date_range")
    if not rng:
        raise RuntimeError(f"{METHOD} returned no available_date_range for {probe}")
    return date.fromisoformat(rng["start_date"]), date.fromisoformat(rng["end_date"])


def windows(start_date, end_date, size=MAX_WINDOW_DAYS):
    cursor = start_date
    while cursor <= end_date:
        last = min(cursor + timedelta(days=size - 1), end_date)
        yield cursor, last
        cursor = last + timedelta(days=1)


def run(conn, start_date=None, end_date=None):
    with ingest_run(conn, SOURCE) as counts:
        client = ProxyClient()

        if start_date is None or end_date is None:
            start_date, end_date = available_range(client)

        for window_start, window_end in windows(start_date, end_date):
            data = client.call(
                METHOD,
                {"start_date": window_start.isoformat(), "end_date": window_end.isoformat()},
            )

            rows = []
            for rec in data.get("stats") or []:
                try:
                    rows.append(team_stats_row(rec))
                    counts.rows_in += 1
                except KeyError as exc:
                    counts.rows_rejected += 1
                    dead_letter(conn, SOURCE, rec, str(exc))

            with conn.cursor() as cur:
                cur.executemany(INSERT_SQL, rows)
            conn.commit()
            print(f"{SOURCE} {window_start}..{window_end}: {len(rows)} rows")

    print(f"{SOURCE} {start_date}..{end_date}: {counts.rows_in} rows, {counts.rows_rejected} rejected")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--backfill", action="store_true")
    group.add_argument("--date", type=date.fromisoformat)
    args = parser.parse_args()

    load_dotenv(ENV_FILE)
    with connect() as conn:
        if args.backfill:
            run(conn)
        else:
            run(conn, args.date, args.date)


if __name__ == "__main__":
    main()
