import pytest
from datetime import date, datetime, timezone

from ingest import analytics_pull, channel_range_pull, member_range_pull, users_list_pull
from lib.proxy_client import InternalApiError

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


def test_user_dim_row_treats_zero_deactivated_ts_as_none():
    row = analytics_pull.user_dim_row(
        {"id": "U1", "date_created": 1600000000, "deactivated_ts": 0, "is_restricted": True}
    )
    assert len(row) == 9
    assert row[0:3] == ("U1", epoch(1600000000), None)
    assert row[7] is True


def test_user_dim_row_carries_real_deactivated_ts():
    row = analytics_pull.user_dim_row({"id": "U1", "deactivated_ts": 1700000000})
    assert row[2] == epoch(1700000000)


def test_user_profile_row_carries_identity_fields():
    user = {"id": "U1", "full_name": "Ada", "username": "ada", "email": "ada@example.com"}
    assert analytics_pull.user_profile_row(user) == ("U1", "Ada", "ada", "ada@example.com")


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


def test_users_list_profile_row_prefers_top_level_real_name():
    user = {"id": "U1", "name": "ada", "real_name": "Ada", "profile": {"real_name": "Ada L", "display_name": "adal"}}
    assert users_list_pull.profile_row(user) == ("U1", "Ada", "adal", "ada")


def test_users_list_profile_row_falls_back_to_profile_real_name():
    user = {"id": "U1", "name": "ada", "profile": {"real_name": "Ada L"}}
    assert users_list_pull.profile_row(user)[1] == "Ada L"


def test_users_list_profile_row_survives_a_missing_profile():
    assert users_list_pull.profile_row({"id": "U1", "name": "ada"}) == ("U1", None, None, "ada")


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
    def __init__(self, edge):
        self.edge = edge
        self.calls = []

    def call(self, method, params):
        asked = date.fromisoformat(params["end_date"])
        self.calls.append(asked)
        if asked > self.edge:
            raise InternalApiError("invalid_arguments")
        return {"ok": True}


def test_discover_end_walks_back_to_the_first_accepted_date():
    client = FakeClient(date(2026, 7, 31))
    assert channel_range_pull.discover_end(client, today=date(2026, 8, 3)) == date(2026, 7, 31)
    assert client.calls == [date(2026, 8, 3), date(2026, 8, 2), date(2026, 8, 1), date(2026, 7, 31)]


def test_discover_end_does_not_swallow_unrelated_errors():
    class Broken(FakeClient):
        def call(self, method, params):
            raise InternalApiError("ratelimited")

    with pytest.raises(InternalApiError, match="ratelimited"):
        channel_range_pull.discover_end(Broken(date(2026, 7, 31)), today=date(2026, 8, 3))


def test_discover_end_gives_up_rather_than_probing_forever():
    client = FakeClient(date(2020, 1, 1))
    with pytest.raises(RuntimeError, match="rejected every date"):
        channel_range_pull.discover_end(client, today=date(2026, 8, 3))
    assert len(client.calls) == channel_range_pull.MAX_PROBE_DAYS + 1
