import argparse
from datetime import date
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect, dead_letter, finish_run, start_run
from lib.internal_client import InternalClient

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"

SOURCE = "team_stats"
METHOD = "team.stats.timeSeries"
RANGE_METHOD = "admin.analytics.getAvailableDateRange"

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


def available_range(client):
    resp = client.call(RANGE_METHOD, {"type": "member"})
    rng = resp.get("available_date_range") or resp
    return date.fromisoformat(rng["start_date"]), date.fromisoformat(rng["end_date"])


def run(conn, start_date=None, end_date=None):
    run_id = start_run(conn, SOURCE)
    rows_in = rows_rejected = 0
    client = InternalClient()

    if start_date is None or end_date is None:
        start_date, end_date = available_range(client)

    data = client.call(
        METHOD,
        {"start_date": start_date.isoformat(), "end_date": end_date.isoformat()},
    )

    rows = []
    for rec in data.get("stats") or []:
        try:
            rows.append(team_stats_row(rec))
            rows_in += 1
        except KeyError as exc:
            rows_rejected += 1
            dead_letter(conn, SOURCE, rec, str(exc))

    with conn.cursor() as cur:
        cur.executemany(INSERT_SQL, rows)
    conn.commit()

    finish_run(conn, run_id, "ok", rows_in, rows_rejected)
    conn.commit()
    print(f"{SOURCE} {start_date}..{end_date}: {rows_in} rows, {rows_rejected} rejected")


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
