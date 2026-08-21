import logging
import threading

from lib.db import connect

from bot.engine import session
from bot.nemo import channel

log = logging.getLogger("bot.nemo")

CASES = "fd_case_changed"
CHAT = "fd_chat_changed"


def redraw(client, case_id, channel_id=None):
    with session() as conn:
        return channel.redraw(client, conn, case_id, channel_id)


def mirror(client, case_id, channel_id=None):
    with session() as conn:
        return channel.mirror(client, conn, case_id, channel_id)


def listen(client, stopping, channel_id=None):
    conn = connect()
    conn.autocommit = True
    conn.execute(f"LISTEN {CASES}")
    conn.execute(f"LISTEN {CHAT}")
    log.info("nemo: listening for case and chat changes")

    try:
        for note in conn.notifies(stop_after=None, timeout=None):
            if stopping.is_set():
                break
            case_id = int(note.payload) if note.payload.isdigit() else None
            if case_id is None:
                continue
            try:
                if note.channel == CHAT:
                    mirror(client, case_id, channel_id)
                else:
                    redraw(client, case_id, channel_id)
            except Exception as failure:
                log.warning("nemo: case %s could not be brought up to date: %s", case_id, failure)
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
