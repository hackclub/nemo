import logging
import threading

from lib.db import connect

log = logging.getLogger("bot.loops")

RETRY_SECONDS = 5


def listen(name, channels, heard, stopping):
    conn = connect()
    conn.autocommit = True
    for channel_name in channels:
        conn.execute(f"LISTEN {channel_name}")
    log.info("%s: listening for %s", name, ", ".join(channels))

    try:
        for note in conn.notifies(stop_after=None, timeout=None):
            if stopping.is_set():
                break
            told = int(note.payload) if note.payload.isdigit() else None
            if told is None:
                continue
            try:
                heard(note.channel, told)
            except Exception as failure:
                log.warning("%s: %s %s could not be handled: %s",
                            name, note.channel, told, failure)
    finally:
        try:
            conn.close()
        except Exception:
            pass


def watching(name, channels, heard, stopping):
    def loop():
        while not stopping.is_set():
            try:
                listen(name, channels, heard, stopping)
            except Exception as failure:
                log.warning("%s: lost the listener, waiting to retry: %s", name, failure)
                if stopping.wait(RETRY_SECONDS):
                    return

    thread = threading.Thread(target=loop, name=f"{name}-watch", daemon=True)
    thread.start()
    return thread


def sweeping(name, seconds, work, stopping):
    def loop():
        log.info("%s: catching up on anything missed, then sweeping every %ss", name, seconds)
        while True:
            try:
                work()
            except Exception:
                log.exception("%s: the sweep failed, trying again next time", name)
            if stopping.wait(seconds):
                return

    thread = threading.Thread(target=loop, name=f"{name}-sweep", daemon=True)
    thread.start()
    return thread
