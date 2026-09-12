import sys

from dotenv import load_dotenv

from jobs import verify_views
from jobs.nightly_sync import run_dbt
from lib.db import AlreadyRunning
from lib.paths import ENV_FILE


def main():
    load_dotenv(ENV_FILE)
    try:
        run_dbt()
    except AlreadyRunning as exc:
        print(f"transform: {exc}")
        return 75
    return verify_views.main()


if __name__ == "__main__":
    sys.exit(main())
