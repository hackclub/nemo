from datetime import date

import pytest

from lib import lease
from lib.walk import (
    COMPLETE,
    NO_FLOOR,
    SHORT,
    UNVERIFIED,
    WalkWrong,
    check_walk,
    covers_what_it_replaces,
    should_prune,
    window_totals,
)


def test_a_full_walk_is_complete_and_may_prune():
    assert check_walk("x", 216_540, 216_540, 500) == COMPLETE
    assert check_walk("x", 216_100, 216_540, 500) == COMPLETE
    assert should_prune(COMPLETE)


def test_a_short_walk_is_a_verdict_not_an_exception_and_never_prunes(capsys):
    assert check_walk("member range", 150_000, 216_540, 500) == SHORT
    assert "short" in capsys.readouterr().out
    assert not should_prune(SHORT)
    assert not should_prune(None)


def test_walking_past_num_found_is_still_wrong():
    with pytest.raises(WalkWrong):
        check_walk("x", 1_200, 500, 500)
    assert check_walk("x", 10, None, 500) is None


def test_backoff_doubles_and_caps():
    assert [lease.backoff(n) for n in range(4)] == [1.0, 2.0, 4.0, 8.0]
    assert lease.backoff(20) == 60.0
    assert 1.0 <= lease.backoff(0, jitter=0.5) <= 1.5


def test_a_floor_of_zero_is_refused_so_the_guard_is_never_disabled_by_accident():
    with pytest.raises(ValueError, match="no floor"):
        check_walk("member analytics", 1, 216_540, 500, short_at=0)
    with pytest.raises(ValueError, match="no floor"):
        check_walk("member analytics", 1, 216_540, 500, short_at=-0.1)


def test_no_floor_reads_unverified_rather_than_claiming_complete():
    assert check_walk("member analytics", 61_940, 100_000, 500, short_at=NO_FLOOR) == UNVERIFIED
    assert not should_prune(UNVERIFIED)
    with pytest.raises(WalkWrong):
        check_walk("member analytics", 101_000, 100_000, 500, short_at=NO_FLOOR)


def test_member_days_declares_no_floor_because_num_found_over_reports():
    from ingest.analytics_pull import MEMBER_SHORT_AT

    assert MEMBER_SHORT_AT is NO_FLOOR
    assert check_walk("member analytics", 75_660, 100_000, 500,
                      short_at=MEMBER_SHORT_AT) == UNVERIFIED


def test_an_unverified_slice_is_never_confused_with_a_verified_one():
    from lib import walk

    assert walk.UNVERIFIED not in (walk.COMPLETE, walk.SHORT)
    assert check_walk("x", 216_100, 216_540, 500) == COMPLETE
    assert check_walk("x", 100, 216_540, 500) == SHORT
    assert check_walk("x", 100, 216_540, 500, short_at=NO_FLOOR) == UNVERIFIED


def test_every_verdict_the_walk_returns_is_a_legal_ledger_state():
    import re

    from lib import walk
    from lib.paths import MIGRATIONS_DIR

    sql = (MIGRATIONS_DIR / "0093_slice_coverage_unverified.sql").read_text()
    allowed = set(re.findall(r"'(\w+)'", sql.split("CHECK")[1].split(")")[0]))
    for verdict in (walk.COMPLETE, walk.SHORT, walk.UNVERIFIED):
        assert verdict in allowed


NEW = (date(2026, 3, 1), date(2026, 3, 30))
OLD = (date(2026, 2, 1), date(2026, 2, 28))
OLDER = (date(2026, 1, 1), date(2026, 1, 31))


def test_a_window_that_matches_what_it_replaces_may_prune():
    landed, held = window_totals([(*NEW, 40_000), (*OLD, 39_900)], NEW)
    assert (landed, held) == (40_000, 39_900)
    assert covers_what_it_replaces(landed, held)


def test_a_window_that_collapses_may_not_prune():
    landed, held = window_totals([(*NEW, 1_200), (*OLD, 40_000)], NEW)
    assert not covers_what_it_replaces(landed, held)


def test_ordinary_churn_still_prunes():
    assert covers_what_it_replaces(39_000, 40_000)
    assert not covers_what_it_replaces(35_000, 40_000)


def test_the_widest_prior_window_is_the_one_to_beat():
    landed, held = window_totals([(*NEW, 30_000), (*OLD, 12_000), (*OLDER, 40_000)], NEW)
    assert held == 40_000
    assert not covers_what_it_replaces(landed, held)


def test_a_first_ever_window_has_nothing_to_replace():
    landed, held = window_totals([(*NEW, 12)], NEW)
    assert (landed, held) == (12, 0)
    assert covers_what_it_replaces(landed, held)
