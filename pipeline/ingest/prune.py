import argparse

from dotenv import load_dotenv

from lib import settings, sources
from lib.db import connect, ingest_run
from lib.paths import ENV_FILE

SOURCE = "prune"

AGED_BY = {
    "raw.member_activity_snapshot": "window_start",
    "raw.channel_activity_snapshot": "window_start",
    "raw.member_channel_message": "searched_at",
    "raw.member_channel_membership": "seen_at",
}

SHARED = frozenset({"raw.member_activity_snapshot", "raw.channel_activity_snapshot"})

COUNT_SQL = "SELECT count(*) FROM {table} WHERE {column} < now() - make_interval(days => %s){scope}"
DELETE_SQL = "DELETE FROM {table} WHERE {column} < now() - make_interval(days => %s){scope}"
SCOPE = " AND source = %s"


def stamp_of(key):
    return sources.runs_as(key)[0].split(":")[0]


def windows(conn):
    asked = []
    for key in sources.KEYS:
        floor = sources.prune_floor(key)
        if not floor:
            continue
        days = settings.retention_days(conn, key)
        if days is None:
            continue
        for table in sources.says(key, "writes"):
            column = AGED_BY.get(table)
            if column:
                stamp = stamp_of(key) if table in SHARED else None
                asked.append((key, table, column, days, stamp))
    return asked


def sweep(conn, key, table, column, days, stamp=None, dry_run=False):
    scope = SCOPE if stamp else ""
    params = (days, stamp) if stamp else (days,)
    with conn.cursor() as cur:
        cur.execute(COUNT_SQL.format(table=table, column=column, scope=scope), params)
        doomed = cur.fetchone()[0]
        if dry_run or not doomed:
            return doomed
        cur.execute(DELETE_SQL.format(table=table, column=column, scope=scope), params)
    conn.commit()
    return doomed


def run(conn, dry_run=False):
    asked = windows(conn)
    if not asked:
        print(f"{SOURCE}: no retention window is set, so nothing is deleted")
        return 0

    with ingest_run(conn, SOURCE) as counts:
        dropped = 0
        for key, table, column, days, stamp in asked:
            gone = sweep(conn, key, table, column, days, stamp, dry_run)
            dropped += gone
            word = "would drop" if dry_run else "dropped"
            scope = f" where source = {stamp}" if stamp else ""
            print(f"{SOURCE}: {table} keeps {days} days by {column}{scope}, {word} {gone} rows ({key})")
        counts.rows_in = dropped
    print(f"{SOURCE}: {dropped} rows past their window across {len(asked)} table(s)")
    return dropped


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        run(conn, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
