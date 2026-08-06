from datetime import date, datetime, timedelta, timezone

from ingest import (
    analytics_pull,
    channel_range_pull,
    first_reply,
    member_history,
    member_range_pull,
    top_posters_pull,
    users_list_pull,
)

PULL_DATE = date(2026, 7, 20)
WINDOW_START = date(2026, 6, 30)
WINDOW_END = date(2026, 7, 29)


def epoch(value):
    return datetime.fromtimestamp(value, tz=timezone.utc)


def test_member_activity_row_carries_day_counts_not_booleans():
    rec = {
        "user_id": "U1",
        "days_active": 4,
        "days_active_desktop": 3,
        "days_active_ios": 0,
        "messages_posted": 12,
        "messages_posted_in_channel": 9,
        "reactions_added": 5,
        "date_last_active": 1700000000,
    }
    row = analytics_pull.member_activity_row(rec, PULL_DATE)
    assert len(row) == 22
    assert row[0:4] == ("U1", PULL_DATE, PULL_DATE, analytics_pull.ANALYTICS_SOURCE)
    assert row[4] == 4
    assert row[5] == 3
    assert row[7] == 0
    assert row[11] == 12
    assert row[12] == 9
    assert row[13] == 5
    assert row[18] == epoch(1700000000)


def test_member_activity_row_carries_a_window_and_its_own_source():
    row = analytics_pull.member_activity_row(
        {"user_id": "U1", "messages_posted": 12}, WINDOW_START, WINDOW_END, member_range_pull.SOURCE
    )
    assert row[0:4] == ("U1", WINDOW_START, WINDOW_END, member_range_pull.SOURCE)
    assert row[11] == 12
    assert member_range_pull.SOURCE != analytics_pull.ANALYTICS_SOURCE


def test_member_activity_row_leaves_api_omitted_fields_null():
    row = analytics_pull.member_activity_row({"user_id": "U1"}, PULL_DATE)
    assert row[9] is None
    assert row[10] is None


def test_member_dim_row_has_no_guest_flag():
    row = analytics_pull.member_dim_row(
        {"user_id": "U1", "date_claimed": 1600000000, "is_invited_guest": True}
    )
    assert row == ("U1", epoch(1600000000), False, True)


def test_channel_activity_row_maps_counts():
    rec = {
        "channel_id": "C1",
        "messages_posted_count": 10,
        "messages_posted_by_members_count": 7,
        "members_who_posted_count": 4,
        "members_who_viewed_count": 30,
        "reactions_added_count": 2,
    }
    row = analytics_pull.channel_activity_row(rec, PULL_DATE)
    assert len(row) == 12
    assert row[0] == "C1"
    assert row[4] == 10
    assert row[5] == 7
    assert row[6] == 4
    assert row[8] == 30
    assert row[9] == 2


def test_channel_dim_row_converts_epoch_fields():
    row = analytics_pull.channel_dim_row(
        {"channel_id": "C1", "visibility": "public", "date_created": 1700000000}
    )
    assert len(row) == 7
    assert row[0] == "C1"
    assert row[5] == epoch(1700000000)


def test_users_list_member_dim_row_reads_the_deleted_flag():
    row = users_list_pull.member_dim_row(
        {"id": "U1", "deleted": True, "is_bot": False, "is_ultra_restricted": True}
    )
    assert len(row) == 9
    assert row[0:3] == ("U1", True, False)
    assert row[7] is True


def test_users_list_member_dim_row_reads_invite_pending_by_presence():
    absent = users_list_pull.member_dim_row({"id": "U1"})
    present = users_list_pull.member_dim_row({"id": "U2", "is_invited_user": True})
    assert absent[8] is False
    assert present[8] is True


FLOOR = date(2026, 7, 1)
EDGE = date(2026, 7, 10)


def test_pending_days_walks_backwards_from_the_newest_missing_day():
    loaded = {date(2026, 7, 3), date(2026, 7, 4)}
    assert analytics_pull.pending_days(loaded, FLOOR, EDGE, 4) == [
        date(2026, 7, 10), date(2026, 7, 9), date(2026, 7, 8), date(2026, 7, 7)
    ]


def test_pending_days_skips_over_a_loaded_run():
    loaded = {date(2026, 7, 9), date(2026, 7, 10)}
    assert analytics_pull.pending_days(loaded, FLOOR, EDGE, 3) == [
        date(2026, 7, 8), date(2026, 7, 7), date(2026, 7, 6)
    ]


def test_pending_days_returns_only_the_newest_when_the_limit_is_one():
    assert analytics_pull.pending_days(set(), FLOOR, EDGE, 1) == [date(2026, 7, 10)]


def test_pending_days_is_empty_when_every_day_is_loaded():
    every = set()
    day = FLOOR
    while day <= EDGE:
        every.add(day)
        day += timedelta(days=1)
    assert analytics_pull.pending_days(every, FLOOR, EDGE, 5) == []


def test_pending_days_never_exceeds_the_limit():
    assert len(analytics_pull.pending_days(set(), FLOOR, EDGE, 3)) == 3


def test_pending_days_ignores_loaded_days_outside_the_calendar():
    loaded = {date(2020, 1, 1), date(2026, 7, 10)}
    assert analytics_pull.pending_days(loaded, FLOOR, EDGE, 2) == [
        date(2026, 7, 9), date(2026, 7, 8)
    ]


AVAIL_START = date(2026, 5, 15)
AVAIL_END = date(2026, 8, 2)


def test_pending_months_repulls_a_month_clipped_by_a_stale_edge():
    stored = {date(2026, 5, 1): date(2026, 5, 31), date(2026, 6, 1): date(2026, 6, 30),
              date(2026, 7, 1): date(2026, 7, 30)}
    assert top_posters_pull.pending_months(stored, AVAIL_START, AVAIL_END) == [
        date(2026, 7, 1), date(2026, 8, 1)
    ]


def test_pending_months_is_empty_when_every_month_is_complete():
    stored = {date(2026, 5, 1): date(2026, 5, 31), date(2026, 6, 1): date(2026, 6, 30),
              date(2026, 7, 1): date(2026, 7, 31), date(2026, 8, 1): AVAIL_END}
    assert top_posters_pull.pending_months(stored, AVAIL_START, AVAIL_END) == []


def test_pending_months_clamps_the_first_month_to_the_available_floor():
    stored = {date(2026, 5, 1): date(2026, 5, 31)}
    pending = top_posters_pull.pending_months(stored, AVAIL_START, AVAIL_END)
    assert date(2026, 5, 1) not in pending


def test_pending_months_returns_everything_when_nothing_is_stored():
    assert top_posters_pull.pending_months({}, AVAIL_START, AVAIL_END) == [
        date(2026, 5, 1), date(2026, 6, 1), date(2026, 7, 1), date(2026, 8, 1)
    ]


def test_verified_date_row_carries_both_dates_from_one_record():
    row = member_range_pull.verified_date_row(
        {"user_id": "U1", "date_created": 1600000000, "date_claimed": 1600000500}
    )
    assert row == (epoch(1600000000), epoch(1600000500), "U1")


def test_verified_date_row_leaves_an_unclaimed_member_null():
    row = member_range_pull.verified_date_row({"user_id": "U1", "date_created": 1600000000})
    assert row == (epoch(1600000000), None, "U1")


def test_range_row_maps_chats_to_member_messages():
    rec = {
        "channel_id": "C1",
        "messages_count": 151576,
        "chats_count": 9,
        "writers_count": 2,
        "readers_count": 3,
        "reactions_count": 1,
        "users_who_reacted_count": 1,
        "huddles_count": 0,
    }
    row = channel_range_pull.range_row(rec, WINDOW_START, WINDOW_END)
    assert len(row) == 11
    assert row[0:4] == ("C1", WINDOW_START, WINDOW_END, channel_range_pull.SOURCE)
    assert row[4] == 151576
    assert row[5] == 9
    assert row[6] == 2
    assert row[7] == 3
    assert row[9] == 1
    assert row[10] == 0


class FakeClient:
    def __init__(self, start="2025-07-01", end="2026-08-01"):
        self.range = {"ok": True, "start_date": start, "end_date": end}
        self.calls = []

    def call(self, method, params):
        self.calls.append((method, params))
        return self.range


def test_resolve_window_reads_the_channel_calendar_not_the_member_one():
    client = FakeClient()
    start, end = channel_range_pull.resolve_window(client)
    assert client.calls == [(channel_range_pull.RANGE_METHOD, {"type": "channel"})]
    assert end == date(2026, 8, 1)
    assert start == date(2026, 7, 3)


def test_resolve_window_clamps_the_start_to_the_calendar_floor():
    client = FakeClient(start="2026-07-20", end="2026-08-01")
    start, end = channel_range_pull.resolve_window(client)
    assert (start, end) == (date(2026, 7, 20), date(2026, 8, 1))


def test_resolve_window_honours_an_explicit_end():
    client = FakeClient()
    start, end = channel_range_pull.resolve_window(client, days=7, end=date(2026, 7, 10))
    assert (start, end) == (date(2026, 7, 4), date(2026, 7, 10))


def test_channel_calendar_accepts_a_nested_range():
    class Nested(FakeClient):
        def call(self, method, params):
            return {"ok": True, "available_date_range": self.range}

    assert channel_range_pull.channel_calendar(Nested()) == (date(2025, 7, 1), date(2026, 8, 1))


def test_history_row_reads_the_first_match():
    messages = {
        "total": 6009,
        "matches": [{"ts": "1606939916.452200", "channel": {"id": "C75M7C0SY", "name": "welcome"}}],
    }
    row = member_history.history_row("U1", messages)
    assert row == ("U1", 6009, epoch(1606939916.4522), "C75M7C0SY")


def test_history_row_records_a_member_who_never_posted():
    assert member_history.history_row("U1", {"total": 0, "matches": []}) == ("U1", 0, None, None)


def test_history_row_survives_a_total_with_no_matches():
    assert member_history.history_row("U1", {"total": 3, "matches": []}) == ("U1", 3, None, None)


def test_scan_replies_skips_self_replies_and_computes_latency():
    posted = epoch(1600000000)
    messages = [
        {"user": "U1", "ts": "1600000000.000000"},
        {"user": "U1", "ts": "1600000060.000000"},
        {"user": "U2", "ts": "1600000840.000000"},
    ]
    assert first_reply.scan_replies("U1", posted, messages) == (
        ("U2", epoch(1600000840), 840), None,
    )


def test_scan_replies_walks_past_a_bot_to_the_first_human():
    posted = epoch(1600000000)
    messages = [
        {"user": "U1", "ts": "1600000000.000000"},
        {"user": "UBOT", "bot_id": "B1", "ts": "1600000004.000000"},
        {"subtype": "bot_message", "bot_id": "B2", "ts": "1600000009.000000"},
        {"user": "U2", "ts": "1600003600.000000"},
    ]
    assert first_reply.scan_replies("U1", posted, messages) == (
        ("U2", epoch(1600003600), 3600), ("UBOT", epoch(1600000004), 4),
    )


def test_scan_replies_keeps_a_bot_only_thread_separate():
    posted = epoch(1600000000)
    messages = [
        {"user": "U1", "ts": "1600000000.000000"},
        {"user": "UBOT", "bot_id": "B1", "ts": "1600000004.000000"},
    ]
    human, bot = first_reply.scan_replies("U1", posted, messages)
    assert human is None
    assert bot == ("UBOT", epoch(1600000004), 4)


def test_scan_replies_carries_a_bot_found_on_an_earlier_page():
    posted = epoch(1600000000)
    earlier_bot = ("UBOT", epoch(1600000004), 4)
    page = [{"user": "U2", "ts": "1600000840.000000"}]
    assert first_reply.scan_replies("U1", posted, page, earlier_bot) == (
        ("U2", epoch(1600000840), 840), earlier_bot,
    )


def test_reply_row_records_an_unanswered_first_post():
    assert first_reply.reply_row("U1", None, None) == (
        "U1", None, None, None, None, None, None, None, None, first_reply.WALK_VERSION,
    )


def test_reply_row_carries_both_repliers():
    human = ("U2", epoch(1600003600), 3600)
    bot = ("UBOT", epoch(1600000004), 4)
    assert first_reply.reply_row("U1", human, bot) == (
        "U1", "U2", epoch(1600003600), 3600, "UBOT", epoch(1600000004), 4,
        None, None, first_reply.WALK_VERSION,
    )


def test_unreadable_row_marks_a_permanent_skip():
    assert first_reply.unreadable_row("U1", "channel_not_found") == (
        "U1", None, None, None, None, None, None, True, "channel_not_found", first_reply.WALK_VERSION,
    )
