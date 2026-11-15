import datetime as dt

import pytest

from bot.core.formatting import short_date
from bot.nemo.views import action

def submission(**over):
    row = {"type_key": "shush", "target_user_id": "U1", "reason": "spamming"}
    row.update(over)
    return row


def block(blocks, block_id):
    return next((one for one in blocks if one.get("block_id") == block_id), None)


@pytest.mark.parametrize(("key", "takes", "needs"), [
    ("shush", True, False),
    ("channel_ban", True, False),
    ("temp_ban", True, True),
    ("indef_ban", False, False),
    ("warning", False, False),
    ("deleted_messages", False, False),
])
def test_takes_expiry_needs_expiry_read_actions_table(key, takes, needs):
    assert (action.takes_expiry(key), action.needs_expiry(key)) == (takes, needs)


def test_deleted_messages_is_a_record_with_no_channel_or_guard():
    assert "deleted_messages" in [one["value"] for one in action.choices()]
    assert action.label("deleted_messages") == "Deleted messages"
    assert not action.takes_channel("deleted_messages")
    assert action.guard_kind("deleted_messages") is None


def label_before_end_row(blocks):
    return blocks[[one.get("block_id") for one in blocks].index(action.UNTIL) - 1]["text"]["text"]


def test_build_blocks_shush_has_optional_end_date_and_time_in_one_row():
    blocks = action.build_blocks(1, submission())
    row = block(blocks, action.UNTIL)

    assert row["type"] == "actions"
    assert [(one["type"], one["action_id"]) for one in row["elements"]] == [
        ("datepicker", action.UNTIL), ("timepicker", action.UNTIL_TIME)]
    assert label_before_end_row(blocks) == "*End, optional*"


def test_build_blocks_temp_ban_end_is_labelled_required():
    assert label_before_end_row(action.build_blocks(1, submission(type_key="temp_ban"))) == "*End*"


def test_build_blocks_keeps_entered_end_and_shows_end_error():
    blocks = action.build_blocks(1, submission(expires_on="2026-10-20", expires_time="14:30"),
                                 end_error="A temporary ban needs an end date.")
    date_element, time_element = block(blocks, action.UNTIL)["elements"]

    assert (date_element["initial_date"], time_element["initial_time"]) == ("2026-10-20", "14:30")
    assert blocks[[one.get("block_id") for one in blocks].index(action.UNTIL) + 1]["elements"][0]["text"] == \
        "A temporary ban needs an end date."


def test_build_blocks_warning_omits_end_row():
    assert block(action.build_blocks(1, submission(type_key="warning")), action.UNTIL) is None


def test_submitted_values_reads_end_date_and_time_from_the_row():
    state = {"values": {action.UNTIL: {action.UNTIL: {"selected_date": "2026-10-20"},
                                       action.UNTIL_TIME: {"selected_time": "14:30"}}}}
    values = action.submitted_values(state)

    assert (values["expires_on"], values["expires_time"]) == ("2026-10-20", "14:30")


@pytest.mark.parametrize(("values", "expected"), [
    ({}, None),
    ({"expires_on": "2026-10-20"}, dt.datetime(2026, 10, 20, 23, 59, 59, tzinfo=dt.UTC)),
    ({"expires_on": "2026-10-20", "expires_time": "14:30"}, dt.datetime(2026, 10, 20, 14, 30, tzinfo=dt.UTC)),
])
def test_expiry_combines_date_and_time_in_utc(values, expected):
    assert action.expiry(values) == expected


def test_expiry_reads_picked_time_in_the_moderator_zone():
    values = {"expires_on": "2026-10-20", "expires_time": "17:30", "timezone": "Europe/Athens"}

    assert action.expiry(values) == dt.datetime(2026, 10, 20, 14, 30, tzinfo=dt.UTC)


def test_validation_errors_shush_without_end_is_valid():
    assert action.validation_errors(submission()) is None


def test_validation_errors_temp_ban_without_end_is_refused():
    assert action.validation_errors(submission(type_key="temp_ban")) == \
        {action.UNTIL: "A temporary ban needs an end date or duration."}


def test_validation_errors_temp_ban_with_duration_only_is_valid():
    assert action.validation_errors(submission(type_key="temp_ban", duration="7d")) is None


def test_validation_errors_end_and_duration_together_is_refused():
    assert action.validation_errors(submission(expires_on="2026-10-20", duration="7d")) == \
        {action.DURATION: "Use End or Duration, not both"}


@pytest.mark.parametrize("text", ["7", "7x", "0m", "53w", "seven days"])
def test_validation_errors_unreadable_duration_is_refused(text):
    assert action.validation_errors(submission(duration=text)) == \
        {action.DURATION: "Enter a duration such as 30m, 12h, 7d or 2w"}


def test_build_blocks_shush_has_optional_duration_input_after_end_row():
    blocks = action.build_blocks(1, submission(duration="12h"))
    ids = [one.get("block_id") for one in blocks]
    duration = block(blocks, action.DURATION)

    assert ids.index(action.DURATION) == ids.index(action.UNTIL) + 1
    assert (duration["type"], duration["optional"], duration["label"]["text"]) == ("input", True, "Duration")
    assert duration["element"]["placeholder"]["text"] == "7d"
    assert duration["element"]["initial_value"] == "12h"


def test_build_blocks_warning_omits_duration():
    assert block(action.build_blocks(1, submission(type_key="warning")), action.DURATION) is None


def test_submitted_values_reads_duration():
    state = {"values": {action.DURATION: {action.DURATION: {"value": " 2w "}}}}

    assert action.submitted_values(state)["duration"] == "2w"


@pytest.mark.parametrize(("text", "length"), [
    ("30m", dt.timedelta(minutes=30)), ("12H", dt.timedelta(hours=12)),
    ("7d", dt.timedelta(days=7)), ("2w", dt.timedelta(weeks=2)),
])
def test_expiry_with_duration_counts_from_submission(text, length):
    submitted_at = dt.datetime(2026, 10, 16, 9, 30, tzinfo=dt.UTC)

    assert action.expiry({"duration": text, "submitted_at": submitted_at}) == submitted_at + length


def test_header_text_with_duration_shows_computed_end():
    submitted_at = dt.datetime.now(dt.UTC).replace(second=0, microsecond=0)
    values = submission(duration="3d", submitted_at=submitted_at)

    assert action.header_text(values) == f"Shush until {short_date((submitted_at + dt.timedelta(days=3)).date())}, " \
        f"{(submitted_at + dt.timedelta(days=3)):%H:%M} UTC"


def test_validation_errors_time_without_date_is_refused():
    assert action.validation_errors(submission(expires_time="14:30")) == \
        {action.UNTIL: "Pick a date for the end time."}


def test_validation_errors_date_and_time_is_valid():
    assert action.validation_errors(submission(expires_on="2026-10-16", expires_time="11:00")) is None


def test_header_text_with_expiry_shows_end_date_and_time():
    on = dt.date.today() + dt.timedelta(days=4)
    values = submission(expires_on=on.isoformat(), expires_time="14:30")

    assert action.header_text(values) == f"Shush until {short_date(on)}, 14:30 UTC"
