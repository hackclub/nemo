import collections
import random
from datetime import date, timedelta

from seed.emit import top_posters


def by_member(end, days=120, members=8):
    rows = {}
    for offset in range(days):
        day = end - timedelta(days=offset)
        for m in range(members):
            rows[(f"U{m}", day)] = (m + offset % 5, 0)
    return rows


def test_a_member_holds_one_row_per_month():
    rows = list(top_posters(random.Random(1), by_member(date(2026, 3, 31)), date(2026, 3, 31)))
    keys = collections.Counter((month, user_id) for month, _, user_id, *_ in rows)
    assert keys and max(keys.values()) == 1


def test_each_window_is_one_calendar_month():
    end = date(2026, 3, 20)
    windows = {(start, stop) for start, stop, *_ in top_posters(random.Random(1), by_member(end), end)}
    assert windows
    for start, stop in windows:
        assert start.day == 1
        assert stop == end or (stop + timedelta(days=1)).day == 1


def test_the_open_month_stops_at_the_last_measured_day():
    end = date(2026, 3, 20)
    rows = list(top_posters(random.Random(1), by_member(end), end))
    assert max(stop for _, stop, *_ in rows) == end
