from checks import headlines
from lib import sources


def test_the_plan_counts_only_the_stages_the_nightly_runs():
    from jobs import nightly_sync

    assert len(sources.NIGHTLY_KEYS) == len(nightly_sync.stages())
    assert len(sources.NIGHTLY_KEYS) < len(sources.KEYS)


def test_a_floor_passes_when_it_is_exceeded():
    state, _ = headlines.bound_verdict("longest unbroken run of member-days", 1100, 15)
    assert state == "ok"


def test_a_floor_fails_when_it_is_not_reached():
    state, _ = headlines.bound_verdict("longest unbroken run of member-days", 9, 15)
    assert state == "differs"


def test_a_ceiling_passes_at_zero():
    state, _ = headlines.bound_verdict("channel daily pull, days behind the walk", 0, 2)
    assert state == "ok"


def test_a_ceiling_fails_above_the_bound():
    state, _ = headlines.bound_verdict("channel daily pull, days behind the walk", 5, 2)
    assert state == "differs"


def test_a_missing_reading_is_not_a_bound_failure():
    assert headlines.bound_verdict("longest unbroken run of member-days", None, 15)[0] == "no data"


def test_the_first_post_coverage_checks_stay_equalities():
    for name in (
        "first-post dates with a day-30 observation",
        "first-post dates with a day-90 observation",
        "first-post dates where visits are knowable",
    ):
        assert name not in headlines.BOUNDS


def test_every_bound_names_a_direction():
    assert set(headlines.BOUNDS.values()) <= {headlines.AT_LEAST, headlines.AT_MOST}


def test_a_bound_state_maps_to_a_recorded_status():
    for state in ("ok", "differs", "no data"):
        assert state in headlines.STATUS_OF
