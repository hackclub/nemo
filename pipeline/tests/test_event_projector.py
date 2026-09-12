import psycopg
import pytest

from ingest import event_projector
from lib.db import RunCounts
from lib.task import LaneAborted


class Conn:
    def __init__(self, rows):
        self.rows = rows
        self.commits = 0
        self.rollbacks = 0
        self.marked = []

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def execute(self, sql, params=None):
        if sql is event_projector.DONE_SQL:
            self.marked.extend(params[0])

    def fetchall(self):
        return self.rows

    def commit(self):
        self.commits += 1

    def rollback(self):
        self.rollbacks += 1


def rows(n):
    return [(f"E{i}", "C1", f"{i}.0", {"text": "hi"}, None) for i in range(n)]


def run_with(monkeypatch, conn, poison_at=None):
    seen = []

    def record(conn_, channel_id, ts, envelope, measured, method, transport, settled):
        seen.append(ts)
        if poison_at is not None and ts == poison_at:
            raise ValueError("poison event")
        return True

    monkeypatch.setattr(event_projector.archive, "record", record)
    monkeypatch.setattr(event_projector, "pending", lambda c, limit: c.rows)
    monkeypatch.setattr(event_projector, "ingest_run", fake_run)
    return seen


class fake_run:
    def __init__(self, conn, source):
        self.counts = RunCounts()

    def __enter__(self):
        return self.counts

    def __exit__(self, *a):
        return False


def test_a_clean_batch_projects_and_marks_every_event(monkeypatch):
    conn = Conn(rows(4))
    seen = run_with(monkeypatch, conn)
    assert event_projector.run(conn) == 4
    assert len(seen) == 4
    assert conn.marked == ["E0", "E1", "E2", "E3"]


def test_one_poison_event_does_not_stall_the_rest(monkeypatch):
    conn = Conn(rows(4))
    seen = run_with(monkeypatch, conn, poison_at="1.0")
    assert event_projector.run(conn) == 4
    assert seen == ["0.0", "1.0", "2.0", "3.0"]
    assert conn.marked == ["E0", "E1", "E2", "E3"]
    assert conn.rollbacks == 1


def test_the_poison_event_is_still_marked_so_the_head_advances(monkeypatch):
    conn = Conn(rows(3))
    run_with(monkeypatch, conn, poison_at="0.0")
    event_projector.run(conn)
    assert "E0" in conn.marked


def test_a_lock_contention_fault_stays_pending_for_the_next_pass(monkeypatch):
    conn = Conn(rows(3))
    run_with(monkeypatch, conn)

    def contended_at_one(conn_, channel_id, ts, envelope, measured, method, transport, settled):
        if ts == "1.0":
            raise psycopg.errors.LockNotAvailable("could not obtain lock")
        return True

    monkeypatch.setattr(event_projector.archive, "record", contended_at_one)

    assert event_projector.run(conn) == 2
    assert conn.marked == ["E0", "E2"]
    assert "E1" not in conn.marked


def test_a_deadlock_fault_also_stays_pending(monkeypatch):
    conn = Conn(rows(1))
    run_with(monkeypatch, conn)

    def always_deadlocked(*a, **k):
        raise psycopg.errors.DeadlockDetected("deadlock detected")

    monkeypatch.setattr(event_projector.archive, "record", always_deadlocked)

    assert event_projector.run(conn) == 0
    assert conn.marked == []


def test_a_systemic_failure_still_aborts_the_lane(monkeypatch):
    conn = Conn(rows(40))
    run_with(monkeypatch, conn, poison_at=None)

    def always_bad(*a, **k):
        raise ValueError("everything is broken")

    monkeypatch.setattr(event_projector.archive, "record", always_bad)
    with pytest.raises(LaneAborted):
        event_projector.run(conn)


def test_nothing_to_project_is_not_a_run(monkeypatch):
    conn = Conn([])
    monkeypatch.setattr(event_projector, "pending", lambda c, limit: [])
    assert event_projector.run(conn) == 0
