import os
import time

from dotenv import load_dotenv

from ingest.member_history import (
    prepare as prepare_member_history,
    search as search_member_history,
)
from lib import settings
from lib.db import SeededDeployment, connect, refuse_if_seeded, set_worker
from lib.heartbeat import heartbeat_loop
from lib.paths import ENV_FILE

WORKER = "member_history_worker"
DEFAULT_POLL_SECONDS = 1800
INPUTS = ("member_days", "member_range", "users_list")


def inputs_landed(conn):
    stamps = [settings.last_ok(conn, key) for key in INPUTS]
    return max((stamp for stamp in stamps if stamp is not None), default=None)


def prepare_if_new(conn, prepared):
    landed = inputs_landed(conn)
    if prepared is not None and (landed is None or landed <= prepared):
        return prepared
    queued = prepare_member_history(conn)
    print(f"{WORKER}: prepared the queue for new inputs, {queued} newly queued")
    return landed


def drain(conn, progress=None):
    searched = 0
    while True:
        limit = settings.limit(conn, "member_history", "batch")
        found = search_member_history(conn, limit)
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
    prepared = None
    while True:
        state = {"note": "draining"}
        try:
            with connect() as conn, heartbeat_loop(WORKER, lambda: state["note"]):
                prepared = prepare_if_new(conn, prepared)
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
