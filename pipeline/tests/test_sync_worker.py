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


def test_sync_worker_sweeps_its_own_orphans_at_startup():
    import inspect

    from jobs import sync_worker

    assert "sweep_my_earlier_boots" in inspect.getsource(sync_worker.main)


def test_both_long_lived_workers_sweep_their_earlier_boots():
    import inspect

    from jobs import archive_worker, sync_worker

    for mod, fn in ((sync_worker, sync_worker.main), (archive_worker, archive_worker.serve)):
        assert "sweep_my_earlier_boots" in inspect.getsource(fn), mod.__name__


def test_startup_releases_strays_immediately_not_after_six_hours():
    import inspect

    from jobs import sync_worker

    main = inspect.getsource(sync_worker.main)
    assert "reap(stale_after_hours=0)" in main, (
        "at startup every claimed request is stranded, because the worker holding it is gone"
    )


def test_the_periodic_reap_keeps_the_six_hour_bar():
    import inspect

    from jobs import sync_worker

    body = inspect.getsource(sync_worker)
    loop = body.split("def main(")[1]
    assert loop.count("reap()") >= 2, "the in-loop reaps must stay time-based"


def test_the_stale_release_covers_cancelling_not_just_claimed():
    from jobs import sync_worker

    assert "status IN ('claimed', 'cancelling')" in sync_worker.RELEASE_STALE_SQL
