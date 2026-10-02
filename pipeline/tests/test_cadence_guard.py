import inspect
from datetime import datetime, timedelta, timezone

from jobs import nightly_sync
from lib import settings


def guard(monkeypatch, last_ok, cadence="daily", enabled=True):
    monkeypatch.setattr(settings, "enabled", lambda conn, key: enabled)
    monkeypatch.setattr(settings, "cadence", lambda conn, key: cadence)
    monkeypatch.setattr(settings, "last_ok", lambda conn, key: last_ok)


def test_a_stage_is_not_due_when_the_night_starts_but_is_when_it_is_reached(monkeypatch):
    last_ok = datetime(2026, 9, 15, 7, 7, tzinfo=timezone.utc)
    guard(monkeypatch, last_ok)

    at_plan_time = datetime(2026, 9, 16, 3, 0, tzinfo=timezone.utc)
    at_stage_time = datetime(2026, 9, 16, 7, 0, tzinfo=timezone.utc)

    assert settings.skip_reason(None, "dim_snapshot", at_plan_time) is not None
    assert settings.skip_reason(None, "dim_snapshot", at_stage_time) is None


def test_the_plan_defers_the_cadence_check(monkeypatch):
    monkeypatch.setattr(nightly_sync, "stages", lambda: [("dim_snapshot", lambda conn: None)])
    plan = nightly_sync.tonight(None)
    assert [why for _, _, why in plan] == [nightly_sync.WHEN_DUE]


def test_a_named_stage_is_forced_and_never_re_checked():
    plan = nightly_sync.stage_plan("team_stats")
    assert plan[0][2] is None
    assert plan[0][2] is not nightly_sync.WHEN_DUE


def test_run_stages_resolves_the_sentinel_before_anything_else():
    body = inspect.getsource(nightly_sync.run_stages)
    assert "if why is WHEN_DUE:" in body
    assert body.index("if why is WHEN_DUE:") < body.index("due_anyway(")


def test_the_daily_period_is_shorter_than_a_day_so_the_hour_can_drift():
    assert settings.PERIOD["daily"] == timedelta(hours=20)
