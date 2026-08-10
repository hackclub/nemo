import sys

from dotenv import load_dotenv

from jobs.nightly_sync import run_dbt
from lib.paths import ENV_FILE


def main():
    load_dotenv(ENV_FILE)
    run_dbt()


if __name__ == "__main__":
    sys.exit(main())
