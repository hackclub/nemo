import threading
from contextlib import contextmanager

from psycopg_pool import ConnectionPool

from lib.db import connect_kwargs

POOL_SIZE = 10

_local = threading.local()
_pool = None
_lock = threading.Lock()


def _shared_pool():
    global _pool
    with _lock:
        if _pool is None:
            _pool = ConnectionPool(
                kwargs=connect_kwargs(), min_size=1, max_size=POOL_SIZE, open=True)
        return _pool


@contextmanager
def _connection():
    conn = getattr(_local, "conn", None)
    if conn is not None:
        yield conn
        return
    with _shared_pool().connection() as conn:
        _local.conn = conn
        try:
            yield conn
        finally:
            _local.conn = None


@contextmanager
def session():
    with _connection() as conn:
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise


def shutdown():
    global _pool
    with _lock:
        pool, _pool = _pool, None
    if pool is None:
        return
    try:
        pool.close()
    except Exception:
        pass
