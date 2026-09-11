from datetime import date

from lib import calendar


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


class Slack:
    def __init__(self, *ends):
        self.ends = list(ends)
        self.calls = 0

    def call(self, method, params):
        self.calls += 1
        end = self.ends[min(self.calls - 1, len(self.ends) - 1)]
        return {"available_date_range": {"start_date": "2024-01-01", "end_date": end}}


def test_the_window_is_cached_within_the_ttl():
    clock, slack = Clock(), Slack("2026-09-10", "2026-09-11")
    assert calendar.available(slack, "member", clock)[1] == date(2026, 9, 10)
    clock.advance(calendar.TTL_SECONDS - 1)
    assert calendar.available(slack, "member", clock)[1] == date(2026, 9, 10)
    assert slack.calls == 1


def test_the_window_moves_once_the_ttl_expires():
    clock, slack = Clock(), Slack("2026-09-10", "2026-09-11")
    assert calendar.available(slack, "member", clock)[1] == date(2026, 9, 10)
    clock.advance(calendar.TTL_SECONDS + 1)
    assert calendar.available(slack, "member", clock)[1] == date(2026, 9, 11)
    assert slack.calls == 2


def test_a_long_lived_worker_never_freezes_at_its_boot_answer():
    clock, slack = Clock(), Slack("2026-09-10", "2026-09-11", "2026-09-12")
    seen = []
    for _ in range(3):
        seen.append(calendar.available(slack, "member", clock)[1])
        clock.advance(24 * 3600)
    assert seen == [date(2026, 9, 10), date(2026, 9, 11), date(2026, 9, 12)]


def test_each_kind_keeps_its_own_window():
    clock, slack = Clock(), Slack("2026-09-10")
    calendar.available(slack, "member", clock)
    calendar.available(slack, "channel", clock)
    assert slack.calls == 2


def test_clear_still_drops_the_cache():
    clock, slack = Clock(), Slack("2026-09-10", "2026-09-11")
    assert calendar.available(slack, "member", clock)[1] == date(2026, 9, 10)
    calendar.clear()
    assert calendar.available(slack, "member", clock)[1] == date(2026, 9, 11)
