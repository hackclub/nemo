from ingest.analytics_pull import lane_outcome

SRC = "admin_analytics_api:member"


def test_every_lane_landing_is_silent_and_clean():
    lines, error = lane_outcome(SRC, asked=6, landed=6, failed=[], pending=[], unavailable=[])
    assert lines == []
    assert error is None


def test_one_landed_day_no_longer_hides_five_failures():
    failed = [f"2026-09-0{i}: ProxyError: proxy returned 503" for i in range(1, 6)]
    lines, error = lane_outcome(SRC, asked=6, landed=1, failed=failed, pending=[], unavailable=[])
    assert error is not None
    assert error.startswith(f"{SRC}: 1 of 6 landed, 5 failed")


def test_no_day_landing_says_so():
    lines, error = lane_outcome(SRC, asked=6, landed=0, failed=["2026-09-01: boom"], pending=[], unavailable=[])
    assert error.startswith(f"{SRC}: no day landed, 1 failed")


def test_pending_days_are_reported_but_not_a_failure():
    lines, error = lane_outcome(SRC, asked=3, landed=2, failed=[], pending=["2026-09-03"], unavailable=[])
    assert error is None
    assert lines == [f"{SRC}: 1 day(s) not exported yet, left for the next run"]


def test_unavailable_days_are_reported_but_not_a_failure():
    lines, error = lane_outcome(SRC, asked=3, landed=2, failed=[], pending=[], unavailable=["2025-08-03"])
    assert error is None
    assert lines == [f"{SRC}: 1 day(s) have no export and will not be retried"]


def test_pending_and_unavailable_together_stay_clean():
    lines, error = lane_outcome(SRC, asked=4, landed=2, failed=[], pending=["a"], unavailable=["b"])
    assert error is None
    assert len(lines) == 2


def test_the_failure_line_is_printed_and_also_raised():
    failed = ["2026-09-02: TimeoutError: read timed out"]
    lines, error = lane_outcome(SRC, asked=2, landed=1, failed=failed, pending=[], unavailable=[])
    assert any("1 of 2 day(s) failed" in line for line in lines)
    assert "read timed out" in error


def test_the_error_carries_every_failed_lane():
    failed = ["d1: A", "d2: B", "d3: C"]
    _, error = lane_outcome(SRC, asked=8, landed=5, failed=failed, pending=[], unavailable=[])
    for detail in failed:
        assert detail in error
