import os
import time

from dotenv import load_dotenv

from ingest.member_history import run as run_member_history
from lib import settings
from lib.db import SeededDeployment, connect, refuse_if_seeded, set_worker
from lib.heartbeat import beating
from lib.paths import ENV_FILE

WORKER = "member_history_worker"
DEFAULT_POLL_SECONDS = 1800


def drain(conn, progress=None):
    searched = 0
    while True:
        limit = settings.limit(conn, "member_history", "batch")
        found = run_member_history(conn, limit)
        if not found:
            return searched
        searched += found
        if progress is not None:
            progress(searched)


def main():
    load_dotenv(ENV_FILE)
    set_worker(WORKER)
    poll = int(os.environ.get("MEMBER_HISTORY_POLL_SECONDS", "") or DEFAULT_POLL_SECONDS)

    with connect() as conn:
        try:
            refuse_if_seeded(conn)
        except SeededDeployment as exc:
            print(f"{WORKER}: {exc}")
            raise SystemExit(1) from exc

    print(f"{WORKER}: draining member_history continuously, {poll}s idle poll")
    while True:
        state = {"note": "draining"}
        try:
            with connect() as conn, beating(WORKER, lambda: state["note"]):
                searched = drain(conn, lambda n: state.update(note=f"draining, {n} searched this wake"))
                state["note"] = (
                    "idle, every member searched" if not searched else f"idle after searching {searched}"
                )
                if searched:
                    print(f"{WORKER}: searched {searched} member(s) this wake")
        except Exception as exc:
            print(f"{WORKER}: drain failed, {type(exc).__name__}: {exc}")
        time.sleep(poll)


if __name__ == "__main__":
    main()
