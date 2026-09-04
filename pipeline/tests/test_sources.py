import pytest

from jobs import nightly_sync
from lib import sources


def test_every_source_declares_its_behaviour():
    for key in sources.KEYS:
        said = sources.source(key)
        missing = [field for field in sources.DECLARED if field not in said]
        assert not missing, f"{key} declares no {', '.join(missing)}"


def test_declared_values_come_from_the_allowed_sets():
    for key in sources.KEYS:
        said = sources.source(key)
        assert said["cadence"] in sources.CADENCES, key
        assert said["guard"] in sources.GUARDS, key
        assert said["resume"] in sources.RESUMES, key
        assert said["retention"] in sources.RETENTIONS, key


def test_nothing_is_pruned_unless_a_window_is_asked_for():
    for key in sources.KEYS:
        assert sources.source(key)["retention"] != "prune", key


def test_a_prune_floor_only_belongs_to_a_source_that_keeps_rows():
    for key in sources.KEYS:
        if sources.prune_floor(key):
            assert sources.source(key)["retention"] == "keep", key


STANDALONE_SOURCES = {"member_history"}


def test_the_nightly_runs_exactly_what_the_file_declares():
    ran = {name for name, _ in nightly_sync.stages()}
    assert ran <= set(sources.KEYS), "a stage must be a declared source"
    assert set(sources.KEYS) - ran == STANDALONE_SOURCES, (
        "a declared source missing from the nightly must be accounted for in STANDALONE_SOURCES, "
        "its own always-on worker rather than a nightly stage"
    )


def test_limits_are_ordered_and_hold_their_default():
    for key in sources.KEYS:
        for name, bounds in (sources.source(key).get("limits") or {}).items():
            assert bounds["min"] <= bounds["default"] <= bounds["max"], f"{key}.{name}"


def test_clamped_holds_a_value_inside_its_bounds():
    assert sources.clamped("member_channels", "batch", 5) == 50
    assert sources.clamped("member_channels", "batch", 9000) == 2000
    assert sources.clamped("member_channels", "batch", 750) == 750
    assert sources.clamped("member_channels", "batch", None) == 600


def test_an_unknown_source_is_refused_rather_than_empty():
    with pytest.raises(sources.Unknown):
        sources.source("teleporter")
    with pytest.raises(sources.Unknown):
        sources.limit("team_stats", "batch")
