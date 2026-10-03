from contextlib import contextmanager

from lib import faults
from lib.db import dead_letter

CONSECUTIVE_FAULTS = 25


class LaneAbortedError(RuntimeError):
    """Raised when consecutive per-entity faults exceed the lane threshold."""


@contextmanager
def per_entity(conn, source, counts, payload, on_entity=None, on_fault=None):
    try:
        yield
    except Exception as exc:
        fault = faults.classify(exc)
        if not fault.continues():
            raise
        conn.rollback()
        if on_fault is not None:
            on_fault(fault)
        if fault.name == "entity" and on_entity is not None:
            on_entity(fault)
        else:
            counts.rows_rejected += 1
            dead_letter(conn, source, payload, f"{fault.name}: {fault.detail}")
            conn.commit()
        counts.consecutive_faults += 1
        if counts.consecutive_faults >= CONSECUTIVE_FAULTS:
            raise LaneAbortedError(
                f"{source}: {counts.consecutive_faults} consecutive {fault.name} faults, "
                f"the last was {fault.detail[:120]}"
            ) from exc
        return
    counts.consecutive_faults = 0
