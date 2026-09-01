import argparse
import re
from datetime import date, timedelta

from dotenv import load_dotenv

from ingest.channel_range_pull import (
    METHOD,
    MONTH_SOURCE,
    RANGE_SQL,
    channel_calendar,
    month_start,
    next_month,
    range_row,
)
from lib.db import connect, dead_letter, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient

SOURCE = MONTH_SOURCE
PAGE_SIZE = 500
SPLIT_DEPTH = 3
TOKEN_SPLIT = re.compile(r"[^0-9a-zÀ-￿]+")

SHARD_SQL = "SELECT name FROM raw.channel_dim WHERE name IS NOT NULL"
ALPHABET_SUFFIX = "abcdefghijklmnopqrstuvwxyz0123456789"


def token_heads(name):
    return {token[0] for token in TOKEN_SPLIT.split(name.lower()) if token}


def shard_alphabet(conn):
    letters = set()
    with conn.cursor() as cur:
        cur.execute(SHARD_SQL)
        for (name,) in cur:
            letters |= token_heads(name)
    return sorted(letters)


def month_window(client, month):
    floor, edge = channel_calendar(client)
    start = month_start(month)
    return max(floor, start), min(edge, next_month(start) - timedelta(days=1))


def interval_of(month):
    return f"{month.year:04d}-{month.month:02d}"


def ask(client, interval, query=None):
    params = {
        "date_interval": interval,
        "privacy": "public",
        "sort_column": "name",
        "sort_direction": "asc",
        "count": PAGE_SIZE,
    }
    if query is not None:
        params["query"] = query
    data = client.call(METHOD, params, max_retries=6)
    return data.get("channel_analytics") or [], data.get("num_found") or 0


def sweep(client, interval, shards, found, depth=0):
    truncated = []
    for shard in shards:
        records, num_found = ask(client, interval, shard)
        for record in records:
            found[record["channel_id"]] = record
        if num_found > len(records):
            truncated.append(shard)
    if not truncated or depth >= SPLIT_DEPTH:
        return truncated
    deeper = [shard + letter for shard in truncated for letter in ALPHABET_SUFFIX]
    return sweep(client, interval, deeper, found, depth + 1)


def run_month(conn, month, alphabet=None):
    client = ProxyClient()
    start, stop = month_window(client, month)
    interval = interval_of(month)
    shards = alphabet or shard_alphabet(conn)
    found = {}

    with ingest_run(conn, SOURCE) as counts:
        _, expected = ask(client, interval)
        counts.total_expected = expected
        short = sweep(client, interval, shards, found)
        rows = []
        for record in found.values():
            try:
                rows.append(range_row(record, start, stop, SOURCE))
            except KeyError as exc:
                counts.rows_rejected += 1
                dead_letter(conn, SOURCE, {"keys": sorted(record)}, str(exc))
        with conn.cursor() as cur:
            cur.executemany(RANGE_SQL, rows)
        counts.rows_in = len(rows)

    missed = expected - len(found)
    print(
        f"channel month {interval}: {len(rows)} of {expected} channels over "
        f"{len(shards)} shard(s), {missed} missed, {counts.rows_rejected} rejected"
        + (f", still truncated: {short}" if short else "")
    )
    return len(rows)


def months_between(client, first=None, last=None):
    floor, edge = channel_calendar(client)
    cursor = month_start(first or floor)
    stop = month_start(last or edge)
    months = []
    while cursor <= stop:
        months.append(cursor)
        cursor = next_month(cursor)
    return months


def run(conn, months=None):
    client = ProxyClient()
    alphabet = shard_alphabet(conn)
    total = 0
    for month in months or months_between(client):
        total += run_month(conn, month, alphabet)
    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--month", type=date.fromisoformat, action="append")
    parser.add_argument("--from", dest="first", type=date.fromisoformat)
    parser.add_argument("--to", dest="last", type=date.fromisoformat)
    args = parser.parse_args()
    load_dotenv(ENV_FILE)
    with connect() as conn:
        if args.month:
            run(conn, args.month)
        elif args.first or args.last:
            run(conn, months_between(ProxyClient(), args.first, args.last))
        else:
            run(conn)


if __name__ == "__main__":
    main()
