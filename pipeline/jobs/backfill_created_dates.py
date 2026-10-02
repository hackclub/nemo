import argparse
import csv
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE

USER_ID_RE = re.compile(r"^[UW][A-Z0-9]+$")

OVERRIDE_SQL = """
INSERT INTO raw.member_created_override (user_id, account_created_verified)
VALUES (%s, %s)
ON CONFLICT (user_id) DO NOTHING
"""


def parse_created(value):
    return datetime.strptime(value.strip(), "%b %d, %Y").replace(tzinfo=timezone.utc)


def rows_from(path):
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            user_id = (row.get("User ID") or "").strip()
            created = row.get("Account created (UTC)") or ""
            if not USER_ID_RE.match(user_id):
                print(f"{path.name}: skipping row with no usable User ID: {row}")
                continue
            try:
                yield user_id, parse_created(created)
            except ValueError:
                print(f"{path.name}: skipping {user_id}, unparseable date {created!r}")


def run(conn, paths):
    seen = {}
    rejected = 0
    for path in paths:
        for user_id, created in rows_from(path):
            if user_id in seen and seen[user_id] != created:
                print(f"conflicting dates within the export for {user_id}: "
                      f"{seen[user_id].date()} vs {created.date()}, keeping the first seen")
                rejected += 1
                continue
            seen[user_id] = created

    rows = list(seen.items())
    ids = list(seen)
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM raw.member_created_override WHERE user_id = ANY(%s)", (ids,))
        before = cur.fetchone()[0]

    with conn.cursor() as cur:
        cur.executemany(OVERRIDE_SQL, rows)
    conn.commit()

    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM raw.member_created_override WHERE user_id = ANY(%s)", (ids,))
        after = cur.fetchone()[0]

    print(f"read {len(rows)} distinct member(s) across {len(paths)} file(s), "
          f"{rejected} rejected for conflicting dates within the export")
    print(f"{before} already had an override before this run, "
          f"{after - before} newly inserted, {after} now in raw.member_created_override")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+", help="one or more Slack member analytics CSV export parts")
    parser.add_argument("--dsn", help="connect to this Postgres DSN instead of the pipeline's own env")
    args = parser.parse_args()
    load_dotenv(ENV_FILE)

    paths = [Path(f) for f in args.files]
    missing = [p for p in paths if not p.exists()]
    if missing:
        print("file(s) not found:", ", ".join(str(p) for p in missing))
        sys.exit(1)

    with connect(args.dsn) as conn:
        run(conn, paths)


if __name__ == "__main__":
    main()
