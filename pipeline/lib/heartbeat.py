import threading
from contextlib import contextmanager

from lib.db import beat, connect

BEAT_SECONDS = 60


def alive(worker, note):
    try:
        with connect() as conn:
            beat(conn, worker, note)
    except Exception as exc:
        print(f"{worker}: heartbeat failed, {type(exc).__name__}: {exc}")


@contextmanager
def beating(worker, note, every=BEAT_SECONDS):
    stop = threading.Event()

    def pulse():
        while True:
            alive(worker, note() if callable(note) else note)
            if stop.wait(every):
                return

    thread = threading.Thread(target=pulse, daemon=True)
    thread.start()
    try:
        yield
    finally:
        stop.set()
        thread.join(timeout=5)
