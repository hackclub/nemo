import contextlib

from bot.core import audit
from bot.nemo import memberguards
from bot.nemo.enforcement import sweep


class Conn:
    def __init__(self, updated=True):
        self.updated = updated
        self.calls = []
        self.row = None

    def execute(self, sql, args=None):
        self.calls.append((sql, args))
        changes_state = sql in (memberguards.START, memberguards.CANCEL)
        self.row = (args[-1],) if changes_state and self.updated else None
        return self

    def fetchone(self):
        return self.row

    def ran(self, sql):
        return [args for statement, args in self.calls if statement == sql]


def due_guard(**overrides):
    return {"id": 5, "kind": "deactivation", "subject_id": "U1", "channel_id": None,
            "reason": "spam", "expires_at": None, "case_id": 9, "opened_by": "UMOD",
            "ended": False, "overlapped": False, **overrides}


def test_due_sql_picks_scheduled_guards_whose_start_has_passed():
    assert "WHERE g.state = 'scheduled' AND g.starts_at <= now()" in memberguards.DUE
    assert "l.state IN ('live', 'lifting')" in memberguards.DUE


def test_start_and_cancel_sql_only_touch_scheduled_guards():
    assert "WHERE id = %s AND state = 'scheduled'" in memberguards.START
    assert "WHERE id = %s AND state = 'scheduled'" in memberguards.CANCEL


def test_unenforced_and_lapsed_sql_skip_scheduled_guards():
    assert "WHERE state = 'live'" in memberguards.UNENFORCED
    assert "WHERE state = 'live'" in memberguards.LAPSED


def test_start_scheduled_puts_due_guard_live_and_audits_opened_by_its_scheduler():
    conn = Conn()

    assert sweep.start_scheduled(conn, due_guard()) is True
    assert conn.ran(memberguards.START) == [(5,)]
    assert conn.ran(memberguards.CANCEL) == []
    [record] = conn.ran(audit.RECORD)
    assert (record[0], record[2], record[3], record[4]) == ("UMOD", "member_guard", 5, "opened")


def test_start_scheduled_cancels_guard_whose_end_passed_before_it_started():
    conn = Conn()

    assert sweep.start_scheduled(conn, due_guard(ended=True)) is True
    assert conn.ran(memberguards.START) == []
    assert conn.ran(memberguards.CANCEL) == [(memberguards.NEMO, sweep.EXPIRED_REASON, 5)]
    [record] = conn.ran(audit.RECORD)
    assert record[4] == "cancelled"


def test_start_scheduled_cancels_guard_when_member_is_already_deactivated():
    conn = Conn()

    assert sweep.start_scheduled(conn, due_guard(overlapped=True)) is True
    assert conn.ran(memberguards.START) == []
    assert conn.ran(memberguards.CANCEL) == [(memberguards.NEMO, sweep.ALREADY_DEACTIVATED, 5)]


def test_start_scheduled_guard_already_moved_records_nothing():
    conn = Conn(updated=False)

    assert sweep.start_scheduled(conn, due_guard()) is False
    assert conn.ran(audit.RECORD) == []


def test_sweep_scheduled_failing_guard_does_not_block_others(monkeypatch):
    started = []

    def start_or_fail(conn, guard):
        if guard["id"] == 1:
            raise RuntimeError("database went away")
        started.append(guard["id"])

    monkeypatch.setattr(sweep, "session", lambda: contextlib.nullcontext(object()))
    monkeypatch.setattr(sweep.memberguards, "due", lambda conn: [due_guard(id=1), due_guard(id=2)])
    monkeypatch.setattr(sweep, "start_scheduled", start_or_fail)

    assert sweep.sweep_scheduled() == 2
    assert started == [2]
