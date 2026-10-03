import threading
from contextlib import contextmanager

from lib.db import connect, record_heartbeat

BEAT_SECONDS = 60


def record(worker, note):
    try:
        with connect() as conn:
            record_heartbeat(conn, worker, note)
    except Exception as exc:
        print(f"{worker}: heartbeat failed, {type(exc).__name__}: {exc}")


@contextmanager
def heartbeat_loop(worker, note, every=BEAT_SECONDS):
    stop = threading.Event()

    def tick():
        while True:
            record(worker, note() if callable(note) else note)
            if stop.wait(every):
                return

    thread = threading.Thread(target=tick, daemon=True)
    thread.start()
    try:
        yield
    finally:
        stop.set()
        thread.join(timeout=5)
