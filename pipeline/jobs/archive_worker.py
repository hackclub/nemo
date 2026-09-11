import os
import signal
import threading

from dotenv import load_dotenv

from ingest.channel_history_pull import run as walk_channels
from ingest.channel_replies_pull import LIVE as replies_pool
from ingest.channel_replies_pull import run as walk_replies
from ingest.event_projector import run as project_events
from lib import settings, shards, work
from lib.db import (
    AlreadyRunning,
    SeededDeployment,
    SyncCancelled,
    cancel_scope,
    connect,
    refuse_if_seeded,
    set_worker,
    sole_instance,
)
from lib.heartbeat import beating
from lib.paths import ENV_FILE

WORKER = "archive_worker"
DEFAULT_POLL_SECONDS = 300
DEFAULT_EVENT_POLL_SECONDS = 60
DEFAULT_HISTORY_BATCH = 200
DEFAULT_REPLIES_BUDGET = 500
DEFAULT_REPLIES_FETCHERS = 4
JOIN_TIMEOUT = 10


def seconds(name, fallback):
    return int(os.environ.get(name, "") or fallback)


def batch(conn):
    asked = os.environ.get("ARCHIVE_HISTORY_BATCH")
    if asked:
        return int(asked)
    return settings.limit(conn, "channel_history", "batch") or DEFAULT_HISTORY_BATCH


def budget():
    return seconds("ARCHIVE_REPLIES_BUDGET", DEFAULT_REPLIES_BUDGET)


def fetchers():
    return seconds("ARCHIVE_REPLIES_FETCHERS", DEFAULT_REPLIES_FETCHERS)


def history(conn):
    return walk_channels(conn, batch(conn))


def replies(conn):
    return walk_replies(conn, budget(), fetchers())


LANES = (
    ("history", history, "ARCHIVE_POLL_SECONDS", DEFAULT_POLL_SECONDS),
    ("replies", replies, "ARCHIVE_POLL_SECONDS", DEFAULT_POLL_SECONDS),
    ("events", project_events, "ARCHIVE_EVENT_POLL_SECONDS", DEFAULT_EVENT_POLL_SECONDS),
)


def note(state):
    lanes = ", ".join(f"{name} {state[name]}" for name, *_ in LANES)
    pool = replies_pool.get("pool")
    return f"{lanes} | {pool.summary()}" if pool else lanes


def lane(name, work, state, stopping, poll):
    def loop():
        while not stopping.is_set():
            try:
                with connect() as conn, cancel_scope(stopping.is_set):
                    moved = work(conn)
                state[name] = f"idle after {moved}" if moved else "idle"
            except SyncCancelled:
                state[name] = "stopped mid-pass"
                return
            except Exception as failure:
                state[name] = f"failed, {type(failure).__name__}"
                print(f"{WORKER}: the {name} lane failed, trying again after the poll: {failure}")
            if stopping.wait(poll):
                return
        state[name] = "stopped"

    thread = threading.Thread(target=loop, name=f"{WORKER}-{name}", daemon=True)
    thread.start()
    return thread


def main():
    load_dotenv(ENV_FILE)
    set_worker(WORKER)
    shards.report()
    try:
        with sole_instance(WORKER):
            return serve()
    except AlreadyRunning as clash:
        print(f"{WORKER}: {clash}")
        return 1


def serve():
    with connect() as conn:
        try:
            refuse_if_seeded(conn)
        except SeededDeployment as refusal:
            print(f"{WORKER}: {refusal}")
            raise SystemExit(1) from refusal

    stopping = threading.Event()
    state = {name: "starting" for name, *_ in LANES}

    def stop(*_):
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(f"{WORKER}: {len(LANES)} lane(s) running independently")
    with beating(WORKER, lambda: note(state)):
        running = [lane(name, work, state, stopping, seconds(var, fallback))
                   for name, work, var, fallback in LANES]
        stopping.wait()
        for thread in running:
            thread.join(timeout=JOIN_TIMEOUT)
        try:
            with connect() as conn:
                work.release_mine(conn)
        except Exception as failure:
            print(f"{WORKER}: could not hand the claimed work back, {type(failure).__name__}: {failure}")

    print(f"{WORKER}: stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
