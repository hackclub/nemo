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
from lib import coverage, sources
from lib.db import connect, dead_letter, ingest_run
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyClient
from lib.walk import SHORT_AT

SOURCE = MONTH_SOURCE
KEY = sources.key_for_run(SOURCE)
PAGE_SIZE = 500
SPLIT_DEPTH = 3
TOKEN_SPLIT = re.compile(r"[^0-9a-zÀ-￿]+")

SHARD_SQL = "SELECT name FROM raw.channel_dim WHERE name IS NOT NULL"
ALPHABET_SUFFIX = "abcdefghijklmnopqrstuvwxyz0123456789"
QUERYABLE = re.compile(r"^[0-9a-z]$")


def token_heads(name):
    return {token[0] for token in TOKEN_SPLIT.split(name.lower()) if token}


def queryable_shards(letters):
    return sorted(letter for letter in letters if QUERYABLE.match(letter))


def shard_alphabet(conn):
    letters = set()
    with conn.cursor() as cur:
        cur.execute(SHARD_SQL)
        for (name,) in cur:
            letters |= token_heads(name)
    return queryable_shards(letters)


def month_window(client, month):
    floor, edge = channel_calendar(client)
    start = month_start(month)
    return max(floor, start), min(edge, next_month(start) - timedelta(days=1))


def interval_of(month):
    return f"{month.year:04d}-{month.month:02d}"


def ask(client, interval, query=None, direction="asc"):
    params = {
        "date_interval": interval,
        "privacy": "public",
        "sort_column": "name",
        "sort_direction": direction,
        "count": PAGE_SIZE,
    }
    if query is not None:
        params["query"] = query
    data = client.call(METHOD, params, max_retries=6)
    return data.get("channel_analytics") or [], data.get("num_found") or 0


def absorb(records, found, on_fresh=None):
    fresh = [record for record in records if record["channel_id"] not in found]
    for record in records:
        found[record["channel_id"]] = record
    if on_fresh and fresh:
        on_fresh(fresh)
    return len(fresh)


def sweep(client, interval, shards, found, on_fresh=None, depth=0):
    truncated = []
    for shard in shards:
        records, num_found = ask(client, interval, shard)
        absorb(records, found, on_fresh)
        if num_found > len(records):
            truncated.append(shard)
    if not truncated or depth >= SPLIT_DEPTH:
        return truncated
    deeper = [shard + letter for shard in truncated for letter in ALPHABET_SUFFIX]
    return sweep(client, interval, deeper, found, on_fresh, depth + 1)


def tail_sweep(client, interval, found, on_fresh=None):
    records, _ = ask(client, interval, direction="desc")
    return absorb(records, found, on_fresh)


def run_month(conn, month, alphabet=None):
    client = ProxyClient.for_source(KEY)
    start, stop = month_window(client, month)
    interval = interval_of(month)
    shards = alphabet or shard_alphabet(conn)
    found = {}

    with ingest_run(conn, SOURCE, slice_key=interval) as counts:
        fence = coverage.claim_slice(conn, KEY, interval, start, stop, counts.run_id)
        if fence is None:
            print(f"channel month {interval}: another worker holds this month, skipping")
            return 0, 0, 0
        _, expected = ask(client, interval)
        counts.total_expected = expected

        def land(records):
            rows = []
            for record in records:
                try:
                    rows.append(range_row(record, start, stop, SOURCE))
                except KeyError as exc:
                    counts.rows_rejected += 1
                    dead_letter(conn, SOURCE, {"keys": sorted(record)}, str(exc))
            with conn.cursor() as cur:
                cur.executemany(RANGE_SQL, rows)
            conn.commit()
            counts.rows_in = len(found)
            counts.progress()

        short = sweep(client, interval, shards, found, land)
        tail = tail_sweep(client, interval, found, land)
        missed = max(0, expected - len(found))
        if short or missed:
            counts.status = "partial"
        reached = len(found) >= int(expected * SHORT_AT)
        coverage.settle(conn, KEY, interval, fence, "complete" if reached and not short else "short",
                        expected, len(found), note=f"{missed} missed" if missed else None)

        print(
            f"channel month {interval}: {len(found)} of {expected} channels over "
            f"{len(shards)} shard(s) plus a tail page that added {tail}, "
            f"{missed} missed, {counts.rows_rejected} rejected"
            + (f", still truncated: {short}" if short else "")
        )

    return len(found), expected, missed


def complete_edge(edge):
    """The latest month-start Slack has fully finished computing, given the newest available day."""
    this_month = month_start(edge)
    if edge >= next_month(this_month) - timedelta(days=1):
        return this_month
    return month_start(this_month - timedelta(days=1))


def months_between(client, first=None, last=None):
    floor, edge = channel_calendar(client)
    cursor = month_start(first or floor)
    stop = month_start(last) if last else complete_edge(edge)
    months = []
    while cursor <= stop:
        months.append(cursor)
        cursor = next_month(cursor)
    return months


def trailing(client, count):
    _, edge = channel_calendar(client)
    months = [complete_edge(edge)]
    while len(months) < max(1, int(count or 1)):
        months.insert(0, month_start(months[0] - timedelta(days=1)))
    return months


def run(conn, months=None, recent=None):
    client = ProxyClient()
    alphabet = shard_alphabet(conn)
    if months is None:
        months = trailing(client, recent) if recent else months_between(client)

    landed = 0
    short = []
    for month in months:
        got, expected, missed = run_month(conn, month, alphabet)
        landed += got
        if missed:
            short.append(f"{interval_of(month)} short by {missed} of {expected}")

    if short:
        print(f"{SOURCE}: " + "; ".join(short))
    return landed


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
