import time

from lib.deadline import Deadline


def test_a_deadline_counts_down_and_expires():
    d = Deadline(0.05)
    assert not d.expired()
    assert 0 < d.remaining() <= 0.05
    time.sleep(0.06)
    assert d.expired()
    assert d.remaining() == 0.0


def test_clamp_never_exceeds_what_is_left():
    d = Deadline(0.5)
    assert d.clamp(60) <= 0.5
    assert d.clamp(0.1) <= 0.1
    assert Deadline(0).clamp(10) == 0.0
