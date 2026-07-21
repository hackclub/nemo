from datetime import date, datetime, timezone

from ingest.analytics_pull import (
    channel_activity_row,
    channel_dim_row,
    member_activity_row,
    member_dim_row,
    member_profile_row,
    user_dim_row,
    user_profile_row,
)

PULL_DATE = date(2026, 7, 20)


def test_member_activity_row_maps_daily_flags_to_ints():
    rec = {
        "user_id": "U1",
        "is_active": True,
        "is_active_ios": False,
        "is_active_desktop": True,
        "is_active_apps": True,
        "is_active_workflows": False,
        "messages_posted_count": 3,
        "reactions_added_count": 5,
    }
    row = member_activity_row(rec, PULL_DATE)
    assert row[0] == "U1"
    assert row[1] == PULL_DATE
    assert row[2] == PULL_DATE
    assert row[4] == 1
    assert row[7] == 0
    assert row[9] == 1
    assert row[10] == 0
    assert row[11] == 3
    assert row[13] == 5


def test_member_profile_row_returns_none_without_email():
    assert member_profile_row({"user_id": "U1"}) is None


def test_member_profile_row_carries_email_only():
    assert member_profile_row({"user_id": "U1", "email_address": "a@example.com"}) == ("U1", "a@example.com")


def test_member_dim_row_parses_claimed_epoch():
    row = member_dim_row({"user_id": "U1", "is_guest": True, "date_claimed": 1600000000})
    assert row == ("U1", True, datetime.fromtimestamp(1600000000, tz=timezone.utc))


def test_channel_activity_row_maps_counts():
    rec = {
        "channel_id": "C1",
        "messages_posted_count": 10,
        "members_who_posted_count": 4,
        "reactions_added_count": 2,
    }
    row = channel_activity_row(rec, PULL_DATE)
    assert row[0] == "C1"
    assert row[4] == 10
    assert row[6] == 4
    assert row[9] == 2


def test_channel_dim_row_converts_epoch_fields():
    rec = {"channel_id": "C1", "visibility": "public", "date_created": 1700000000}
    row = channel_dim_row(rec)
    assert row[0] == "C1"
    assert row[5] == datetime.fromtimestamp(1700000000, tz=timezone.utc)


def test_user_dim_row_treats_zero_deactivated_ts_as_none():
    row = user_dim_row({"id": "U1", "date_created": 1600000000, "deactivated_ts": 0})
    assert row == ("U1", datetime.fromtimestamp(1600000000, tz=timezone.utc), None)


def test_user_dim_row_carries_real_deactivated_ts():
    row = user_dim_row({"id": "U1", "deactivated_ts": 1700000000})
    assert row[2] == datetime.fromtimestamp(1700000000, tz=timezone.utc)


def test_user_profile_row_carries_identity_fields():
    user = {"id": "U1", "full_name": "Ada", "username": "ada", "email": "ada@example.com"}
    assert user_profile_row(user) == ("U1", "Ada", "ada", "ada@example.com")
