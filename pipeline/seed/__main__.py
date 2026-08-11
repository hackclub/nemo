import argparse
import os
import time
from datetime import date

from dotenv import load_dotenv

from lib.db import connect
from lib.paths import ENV_FILE
from seed import SCALES
from seed.emit import analyze, clear, write, write_conduct, write_runs
from seed.generate import HISTORY_MONTHS, build, events
from seed.guards import SeedRefused, check
from seed.hostile import poison_channels

TRUTHY = {"1", "true", "yes", "on"}


def parse_args(argv=None):
    parser = argparse.ArgumentParser(prog="seed")
    parser.add_argument("--scale", choices=sorted(SCALES), default="dev")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--as-of", type=date.fromisoformat)
    parser.add_argument("--history-months", type=int, default=HISTORY_MONTHS)
    parser.add_argument(
        "--hostile",
        action="store_true",
        default=os.environ.get("SEED_HOSTILE", "").strip().lower() in TRUTHY,
    )
    parser.add_argument("--force", action="store_true")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    load_dotenv(ENV_FILE)
    with connect() as conn:
        try:
            dbname, mode = check(conn, force=args.force)
        except SeedRefused as exc:
            print(f"seed: {exc}")
            raise SystemExit(2) from exc

    as_of = args.as_of or date.today()
    print(
        f"seed: target {dbname}, currently {mode}, scale {args.scale} "
        f"({SCALES[args.scale]} members), rng {args.seed}, as of {as_of}"
        f"{', hostile fixtures on' if args.hostile else ''}"
    )

    started = time.monotonic()
    channels, members, profile, as_of, rng = build(
        SCALES[args.scale], args.seed, as_of, history_months=args.history_months
    )
    stream = events(rng, members, profile, as_of)
    print(f"seed: generated {len(members)} members and {len(channels)} channels")
    if args.hostile:
        print(f"seed: poisoned {poison_channels(rng, channels)} channel names")

    with connect() as conn:
        clear(conn, force=args.force)
        counts = write(
            conn, channels, members, profile, as_of, rng, stream, args.scale, args.seed,
            hostile=args.hostile,
        )
        counts.update(write_runs(conn, rng, members, as_of, hostile=args.hostile))
        counts.update(write_conduct(conn, args.seed, members, as_of))
        notices = analyze(conn)

    for name, count in counts.items():
        print(f"seed:   {name}: {count} rows")
    for notice in notices:
        print(f"seed: postgres said: {notice}")
    print(
        f"seed: wrote {sum(counts.values())} rows in {time.monotonic() - started:.1f}s. "
        f"{dbname} is now marked seeded, run dbt build next"
    )


if __name__ == "__main__":
    main()
