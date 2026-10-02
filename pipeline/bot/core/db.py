import threading
from contextlib import contextmanager

from lib.db import connect

_local = threading.local()
_open = []
_lock = threading.Lock()


def _connection():
    conn = getattr(_local, "conn", None)
    if conn is None or conn.closed:
        conn = connect()
        _local.conn = conn
        with _lock:
            _open.append(conn)
    return conn


@contextmanager
def session():
    conn = _connection()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def shutdown():
    with _lock:
        conns, _open[:] = list(_open), []
    for conn in conns:
        try:
            conn.close()
        except Exception:
            pass
