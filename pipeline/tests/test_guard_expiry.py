import contextlib
import datetime as dt
import threading
import time
from types import SimpleNamespace

import pytest

from bot.core import loops
from bot.nemo import guards, loop, memberguards
from bot.nemo.enforcement import sweep

NOW = dt.datetime(2026, 10, 15, 12, 0, tzinfo=dt.timezone.utc)


class Conn:
    def __init__(self, row=None):
        self.row = row
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append(sql)
        return self

    def fetchone(self):
        return self.row


@contextlib.contextmanager
def session_of(conn):
    yield conn


def load_guard_cache(monkeypatch, shushes=None, bans=None):
    monkeypatch.setattr(memberguards, "_shushes", shushes or {})
    monkeypatch.setattr(memberguards, "_bans", bans or {})
    monkeypatch.setattr(memberguards, "_loaded", True)


@pytest.mark.parametrize(("expires_at", "in_force"), [
    (None, True),
    (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1), True),
    (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=1), False),
])
def test_active_shush_returns_guard_only_when_in_force(monkeypatch, expires_at, in_force):
    guard = {"id": 1, "subject_id": "USUB", "expires_at": expires_at}
    load_guard_cache(monkeypatch, shushes={"USUB": guard})

    assert (memberguards.active_shush("USUB") is guard) is in_force


def test_active_ban_expired_guard_returns_none(monkeypatch):
    expired = {"id": 2, "expires_at": dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=1)}
    load_guard_cache(monkeypatch, bans={("USUB", "C_BANNED"): expired})

    assert memberguards.active_ban("USUB", "C_BANNED") is None


def test_in_force_compares_expiry_against_now_argument():
    guard = {"expires_at": NOW}

    assert memberguards.in_force(guard, now=NOW - dt.timedelta(seconds=1)) is True
    assert memberguards.in_force(guard, now=NOW) is False


def test_active_on_thread_sql_excludes_expired_lock():
    assert "AND (expires_at IS NULL OR expires_at > now())" in guards.ACTIVE_ON_THREAD


def test_next_expiry_sql_selects_member_thread_and_channel_guards():
    assert "FROM fd.member_guards" in sweep.NEXT_EXPIRY
    assert "SELECT min(starts_at) FROM fd.member_guards WHERE state = 'scheduled'" in sweep.NEXT_EXPIRY
    assert "FROM fd.thread_guards" in sweep.NEXT_EXPIRY
    assert "kind = 'lock' AND state IN ('warned', 'running')" in sweep.NEXT_EXPIRY
    assert "FROM fd.channel_guards" in sweep.NEXT_EXPIRY


@pytest.mark.parametrize(("row", "seconds"), [((12.5,), 12.5), ((None,), None), (None, None)])
def test_seconds_to_next_expiry_returns_row_value_or_none(row, seconds):
    assert sweep.seconds_to_next_expiry(Conn(row=row)) == seconds


def test_lift_expired_starts_scheduled_then_lifts_member_lock_and_channel_guards_in_order(monkeypatch):
    lift_calls = []
    monkeypatch.setattr(loop, "session", lambda: session_of(Conn()))
    monkeypatch.setattr(loop.sweep, "sweep_scheduled", lambda: lift_calls.append("scheduled"))
    monkeypatch.setattr(loop.sweep, "sweep_lapsed", lambda client: lift_calls.append("member guards"))
    monkeypatch.setattr(loop.guards, "expired_locks", lambda conn: [7, 8])
    monkeypatch.setattr(loop.guard_actions, "lift_lock", lambda client, guard_id: lift_calls.append(guard_id))
    monkeypatch.setattr(loop.channelguards, "lift_lapsed",
                        lambda conn: lift_calls.append("channel guards") or [(9, "slowmode", "C1", "1.0")])
    monkeypatch.setattr(loop.channelguards, "refresh", lambda conn: lift_calls.append("refreshed"))
    monkeypatch.setattr(loop.sweep, "seconds_to_next_expiry", lambda conn: 42.0)

    assert loop.lift_expired(object()) == 42.0
    assert lift_calls == ["scheduled", "member guards", 7, 8, "channel guards", "refreshed"]


def run_on_timer(work, **options):
    stopping = threading.Event()
    wake = loops.run_on_timer("test", work, stopping, **options)
    return stopping, wake


def wait_for(condition, seconds=2.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.01)
    return False


def test_run_on_timer_work_returning_seconds_reruns_after_delay():
    calls = []
    stopping, _ = run_on_timer(lambda: calls.append(time.monotonic()) or 0.05, max_wait_seconds=5.0, retry_seconds=5.0)

    try:
        assert wait_for(lambda: len(calls) >= 3)
    finally:
        stopping.set()


def test_run_on_timer_work_returning_none_waits_for_wake():
    calls = []
    stopping, wake = run_on_timer(lambda: calls.append(1) and None, max_wait_seconds=5.0, retry_seconds=5.0, debounce_seconds=0.0)

    try:
        assert wait_for(lambda: len(calls) == 1)
        time.sleep(0.1)
        assert len(calls) == 1
        wake()
        assert wait_for(lambda: len(calls) == 2)
    finally:
        stopping.set()
        wake()


@pytest.mark.parametrize("outcome", [0.0, -3.0, "raise"])
def test_run_on_timer_overdue_or_failing_work_waits_retry_seconds(outcome):
    calls = []

    def work():
        calls.append(time.monotonic())
        if outcome == "raise":
            raise RuntimeError("slack is down")
        return outcome

    stopping, wake = run_on_timer(work, max_wait_seconds=5.0, retry_seconds=0.2)

    try:
        assert wait_for(lambda: len(calls) >= 2)
        assert calls[1] - calls[0] >= 0.15
    finally:
        stopping.set()
        wake()


def notify_handler(monkeypatch):
    timer_runs, listener = [], {}
    monkeypatch.setattr(loop, "session", lambda: session_of(Conn()))
    for module in (loop.guards, loop.channelguards, loop.memberguards, loop.automod,
                   loop.responses, loop.screening, loop.categories):
        monkeypatch.setattr(module, "refresh", lambda conn: 0)
    monkeypatch.setattr(loop.channel, "refresh_channels", lambda conn: None)
    monkeypatch.setattr(loop.purge, "requeue_interrupted", lambda conn: [])
    monkeypatch.setattr(loop.loops, "run_on_wake", lambda *args, **kwargs: (lambda: None))
    monkeypatch.setattr(loop.loops, "start_listener",
                        lambda name, names, on_notify, stopping: listener.update(on_notify=on_notify))
    monkeypatch.setattr(loop.loops, "run_periodically", lambda *args, **kwargs: None)
    monkeypatch.setattr(loop.loops, "run_on_timer", lambda *args, **kwargs: (lambda: timer_runs.append(1)))
    monkeypatch.setattr(loop.guard_actions, "run_destroy", lambda client, payload: None)
    monkeypatch.setattr(loop.guard_actions, "after_guard_change", lambda client, payload: None)
    monkeypatch.setattr(loop, "join_and_post_notices", lambda client, channel_id: None)

    loop.start(SimpleNamespace(client=None), threading.Event())
    return listener["on_notify"], timer_runs


@pytest.mark.parametrize("channel_name", [loop.MEMBER_GUARD, loop.GUARD, loop.CHANNEL_GUARD])
def test_loop_start_guard_notification_runs_lapse_timer(monkeypatch, channel_name):
    on_notify, timer_runs = notify_handler(monkeypatch)

    on_notify(channel_name, "7")

    assert timer_runs == [1]
