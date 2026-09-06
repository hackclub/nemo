from datetime import date

from lib import planners


def test_day_planner_lists_missing_days_newest_first_and_honours_the_limit():
    floor, edge = date(2026, 9, 1), date(2026, 9, 6)
    covered = {date(2026, 9, 2), "2026-09-04"}
    assert planners.day(floor, edge, covered) == [
        date(2026, 9, 6), date(2026, 9, 5), date(2026, 9, 3), date(2026, 9, 1),
    ]
    assert planners.day(floor, edge, covered, limit=2) == [date(2026, 9, 6), date(2026, 9, 5)]
    assert planners.day(floor, edge, covered, limit=0) == []
    assert planners.day(floor, edge, set(), newest_first=False)[0] == floor


def test_month_planner_skips_covered_months_and_can_drop_the_open_month():
    floor, edge = date(2026, 6, 15), date(2026, 9, 6)
    months = planners.month(floor, edge, {"2026-07"})
    assert months == [date(2026, 6, 1), date(2026, 8, 1), date(2026, 9, 1)]
    assert planners.month(floor, edge, set(), complete_only=True)[-1] == date(2026, 8, 1)
    assert planners.month(floor, date(2026, 9, 30), set(), complete_only=True)[-1] == date(2026, 9, 1)


def test_window_planner_clamps_to_the_calendar():
    floor, edge = date(2025, 8, 4), date(2026, 9, 4)
    assert planners.window(floor, edge) == (floor, edge)
    assert planners.window(floor, edge, days=30) == (date(2026, 8, 6), edge)
    assert planners.window(floor, edge, days=30, end=date(2026, 1, 31)) == (date(2026, 1, 2), date(2026, 1, 31))
    assert planners.window(floor, edge, days=3000) == (floor, edge)
    assert planners.window(floor, edge, end=date(2030, 1, 1)) == (floor, edge)


def test_snapshot_and_slice_key():
    edge = date(2026, 9, 4)
    assert planners.snapshot(edge, set()) == [edge]
    assert planners.snapshot(edge, {"2026-09-04"}) == []
    assert planners.slice_key(edge, edge) == "2026-09-04"
    assert planners.slice_key(date(2026, 8, 6), edge) == "2026-08-06..2026-09-04"
