from datetime import datetime

import pytest

from jobs.nightly_sync import stage_plan
from jobs.sync_worker import next_run_at, wait_seconds


def test_a_later_time_today_stays_today():
    now = datetime(2026, 8, 4, 1, 30)
    assert next_run_at("03:00", now) == datetime(2026, 8, 4, 3, 0)


def test_an_earlier_time_moves_to_tomorrow():
    now = datetime(2026, 8, 4, 5, 30)
    assert next_run_at("03:00", now) == datetime(2026, 8, 5, 3, 0)


def test_the_exact_scheduled_minute_moves_to_tomorrow():
    now = datetime(2026, 8, 4, 3, 0)
    assert next_run_at("03:00", now) == datetime(2026, 8, 5, 3, 0)


def test_it_rolls_over_a_month_boundary():
    now = datetime(2026, 8, 31, 23, 59)
    assert next_run_at("03:00", now) == datetime(2026, 9, 1, 3, 0)


def test_seconds_are_dropped():
    now = datetime(2026, 8, 4, 2, 59, 59, 999999)
    assert next_run_at("03:00", now) == datetime(2026, 8, 4, 3, 0, 0, 0)


def test_the_wait_never_overshoots_the_scheduled_run():
    now = datetime(2026, 8, 4, 2, 59, 50)
    scheduled = datetime(2026, 8, 4, 3, 0)
    assert wait_seconds(60, scheduled, now) == 10.0


def test_the_wait_is_capped_by_the_poll_interval():
    now = datetime(2026, 8, 4, 12, 0)
    scheduled = datetime(2026, 8, 5, 3, 0)
    assert wait_seconds(60, scheduled, now) == 60.0


def test_the_wait_never_drops_below_a_second():
    now = datetime(2026, 8, 4, 3, 0)
    scheduled = datetime(2026, 8, 4, 3, 0)
    assert wait_seconds(60, scheduled, now) == 1.0


def test_stage_plan_selects_one_named_stage():
    plan = stage_plan("team_stats")
    assert len(plan) == 1
    assert plan[0][0] == "team_stats"


def test_stage_plan_rejects_an_unknown_stage():
    with pytest.raises(ValueError):
        stage_plan("not_a_stage")
