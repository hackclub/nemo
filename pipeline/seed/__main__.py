import argparse
from datetime import date
from pathlib import Path

from dotenv import load_dotenv

from lib.db import connect
from seed import SCALES
from seed.guards import SeedRefused, check

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"


def parse_args(argv=None):
    parser = argparse.ArgumentParser(prog="seed")
    parser.add_argument("--scale", choices=sorted(SCALES), default="dev")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--as-of", type=date.fromisoformat)
    parser.add_argument("--hostile", action="store_true")
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
    print("seed: guards passed. nothing to generate yet")


if __name__ == "__main__":
    main()
