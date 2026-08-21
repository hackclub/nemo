import logging
import threading

from lib.db import connect

log = logging.getLogger("bot.nemo")

CASES = "fd_case_changed"
CHAT = "fd_chat_changed"
OUTBOX = "fd_outbox_waiting"


def listen(relay, stopping):
    conn = connect()
    conn.autocommit = True
    for heard in (CASES, CHAT, OUTBOX):
        conn.execute(f"LISTEN {heard}")
    log.info("bot: listening for cases, chat and the outbox")

    try:
        for note in conn.notifies(stop_after=None, timeout=None):
            if stopping.is_set():
                break
            told = int(note.payload) if note.payload.isdigit() else None
            if told is None:
                continue
            try:
                if note.channel == CHAT:
                    relay.mirror(told)
                elif note.channel == OUTBOX:
                    relay.deliver(told)
                else:
                    relay.redraw(told)
            except Exception as failure:
                log.warning("bot: %s %s could not be handled: %s", note.channel, told, failure)
    finally:
        try:
            conn.close()
        except Exception:
            pass


def start(relay, stopping):
    def loop():
        while not stopping.is_set():
            try:
                listen(relay, stopping)
            except Exception as failure:
                log.warning("bot: lost the listener, waiting to retry: %s", failure)
                if stopping.wait(5):
                    return

    thread = threading.Thread(target=loop, name="bot-watch", daemon=True)
    thread.start()
    return thread
