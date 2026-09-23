from datetime import datetime, timedelta

import pytest

from jobs.nightly_sync import stage_plan
from jobs.sync_worker import missed_tonight, next_run_at, slot_today, wait_seconds


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


def test_a_boot_after_the_slot_with_no_run_is_a_missed_night():
    now = datetime(2026, 9, 20, 9, 51)
    assert missed_tonight("03:00", now, already_ran=False)


def test_a_boot_after_the_slot_does_not_rerun_a_night_that_already_ran():
    now = datetime(2026, 9, 20, 9, 51)
    assert not missed_tonight("03:00", now, already_ran=True)


def test_a_boot_before_the_slot_waits_for_it():
    now = datetime(2026, 9, 20, 2, 36)
    assert not missed_tonight("03:00", now, already_ran=False)


def test_the_slot_minute_itself_counts_as_missed():
    now = datetime(2026, 9, 20, 3, 0)
    assert missed_tonight("03:00", now, already_ran=False)


def test_the_slot_is_read_the_same_way_the_schedule_reads_it():
    now = datetime(2026, 9, 20, 9, 51)
    assert slot_today("03:00", now) == datetime(2026, 9, 20, 3, 0)
    assert next_run_at("03:00", now) == slot_today("03:00", now) + timedelta(days=1)


def test_a_catch_up_cannot_tell_itself_to_run_twice():
    import inspect

    from jobs import sync_worker

    main = inspect.getsource(sync_worker.main)
    assert "elif missed_tonight(" in main, (
        "the catch-up must not run alongside NIGHTLY_RUN_AT_START, which has no same-day guard"
    )


def test_an_unreadable_ledger_refuses_to_catch_up():
    import inspect

    from jobs import sync_worker

    body = inspect.getsource(sync_worker.ran_today)
    assert "return True" in body, "a failed lookup must not queue a second nightly"


def test_the_catch_up_asks_for_the_same_date_start_run_stamps():
    from jobs import sync_worker
    from lib import db

    assert "logical_date = current_date" in sync_worker.RAN_TODAY_SQL
    assert "current_date" in db.START_RUN_SQL


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
