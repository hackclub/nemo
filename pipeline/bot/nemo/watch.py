import logging
import threading

from lib.db import connect

from bot.engine import session
from bot.nemo import channel

log = logging.getLogger("bot.nemo")

CHANNEL = "fd_case_changed"


def redraw(client, case_id, channel_id=None):
    with session() as conn:
        return channel.redraw(client, conn, case_id, channel_id)


def listen(client, stopping, channel_id=None):
    conn = connect()
    conn.autocommit = True
    conn.execute(f"LISTEN {CHANNEL}")
    log.info("nemo: listening for case changes")

    try:
        for note in conn.notifies(stop_after=None, timeout=None):
            if stopping.is_set():
                break
            case_id = int(note.payload) if note.payload.isdigit() else None
            if case_id is None:
                continue
            try:
                redraw(client, case_id, channel_id)
            except Exception as failure:
                log.warning("nemo: case %s could not be redrawn: %s", case_id, failure)
    finally:
        try:
            conn.close()
        except Exception:
            pass


def start(client, stopping, channel_id=None):
    def loop():
        while not stopping.is_set():
            try:
                listen(client, stopping, channel_id)
            except Exception as failure:
                log.warning("nemo: lost the case listener, waiting to retry: %s", failure)
                if stopping.wait(5):
                    return

    thread = threading.Thread(target=loop, name="nemo-watch", daemon=True)
    thread.start()
    return thread
