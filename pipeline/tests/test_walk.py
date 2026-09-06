import pytest

from lib import lease
from lib.walk import COMPLETE, SHORT, WalkWrong, check_walk, should_prune


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
