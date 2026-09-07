import os
import time

from dotenv import load_dotenv

from ingest.channel_history_pull import run as walk_channels
from ingest.channel_replies_pull import run as walk_replies
from ingest.event_projector import run as project_events
from lib import settings
from lib.db import SeededDeployment, connect, refuse_if_seeded, set_worker
from lib.heartbeat import beating
from lib.paths import ENV_FILE

WORKER = "archive_worker"
DEFAULT_POLL_SECONDS = 300
DEFAULT_HISTORY_BATCH = 200
DEFAULT_REPLIES_BUDGET = 500


def batch(conn):
    asked = os.environ.get("ARCHIVE_HISTORY_BATCH")
    if asked:
        return int(asked)
    return settings.limit(conn, "channel_history", "batch") or DEFAULT_HISTORY_BATCH


def budget():
    return int(os.environ.get("ARCHIVE_REPLIES_BUDGET", "") or DEFAULT_REPLIES_BUDGET)


def pass_over(conn, note=None):
    projected = project_events(conn)
    if note:
        note("walking channel history")
    walked = walk_channels(conn, batch(conn))
    if note:
        note("draining thread replies")
    replies = walk_replies(conn, budget())
    return projected, walked, replies


def main():
    load_dotenv(ENV_FILE)
    set_worker(WORKER)
    poll = int(os.environ.get("ARCHIVE_POLL_SECONDS", "") or DEFAULT_POLL_SECONDS)

    with connect() as conn:
        try:
            refuse_if_seeded(conn)
        except SeededDeployment as refusal:
            print(f"{WORKER}: {refusal}")
            raise SystemExit(1) from refusal

    print(f"{WORKER}: archiving continuously, {poll}s idle poll")
    while True:
        state = {"note": "starting"}
        try:
            with connect() as conn, beating(WORKER, lambda: state["note"]):
                state["note"] = "projecting events"
                projected, walked, replies = pass_over(
                    conn, lambda said: state.update(note=said))
                moved = projected + walked + replies
                state["note"] = (
                    f"idle, {projected} event(s), {walked} channel(s), {replies} thread(s)"
                    if moved else "idle, nothing waiting"
                )
                print(f"{WORKER}: {projected} event(s) projected, {walked} channel(s) walked, "
                      f"{replies} thread(s) drained")
        except KeyboardInterrupt:
            print(f"{WORKER}: stopped")
            return 0
        except Exception as failure:
            print(f"{WORKER}: pass failed, trying again after the poll: {failure}")
        time.sleep(poll)


if __name__ == "__main__":
    raise SystemExit(main())
