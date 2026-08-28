from jobs.nightly_sync import over_budget


def test_no_budget_never_cuts():
    assert over_budget(999, None, 5, "team_stats") is None
    assert over_budget(999, 0, 5, "team_stats") is None


def test_at_least_one_stage_runs_before_the_budget_can_cut():
    assert over_budget(999, 45, 0, "team_stats") is None
    assert over_budget(999, 45, 1, "team_stats") is not None


def test_the_build_is_never_cut():
    assert over_budget(999, 45, 5, "dbt") is None


def test_inside_the_budget_nothing_is_cut():
    assert over_budget(44.9, 45, 5, "team_stats") is None
    assert over_budget(45, 45, 5, "team_stats") is not None


def test_the_reason_says_what_was_spent():
    assert "46 of 45 minutes" in over_budget(45.6, 45, 5, "member_days")
