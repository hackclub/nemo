import contextlib
import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from bot.nemo import handlers, memberguards, profile
from bot.nemo.views import action, lengths

ATHENS = ZoneInfo("Europe/Athens")
NOW = dt.datetime(2027, 10, 16, 9, 30, tzinfo=dt.UTC)


def test_end_row_renders_label_then_date_and_time_pickers():
    label, row = lengths.end_row("end", "End, optional")

    assert label["text"]["text"] == "*End, optional*"
    assert row["block_id"] == "end"
    assert [(one["type"], one["action_id"]) for one in row["elements"]] == [
        ("datepicker", "end_date"), ("timepicker", "end_time")]


def test_end_row_accepts_initial_values_error_and_custom_action_ids():
    blocks = lengths.end_row("end", "End", ("2027-10-20", "09:00"), "Select the end date.",
                             date_action="d", time_action="t")
    date_element, time_element = blocks[1]["elements"]

    assert (date_element["action_id"], date_element["initial_date"]) == ("d", "2027-10-20")
    assert (time_element["action_id"], time_element["initial_time"]) == ("t", "09:00")
    assert blocks[2]["elements"][0]["text"] == "Select the end date."


def test_initial_of_converts_to_the_viewer_zone():
    at = dt.datetime(2027, 10, 17, 14, 30, tzinfo=dt.UTC)

    assert lengths.initial_of(at, ATHENS) == ("2027-10-17", "17:30")
    assert lengths.initial_of(None) == (None, None)


def test_picked_reads_date_and_time_actions():
    values = {"end": {"end_date": {"selected_date": "2027-10-20"}, "end_time": {"selected_time": "09:15"}}}

    assert lengths.picked(values, "end") == ("2027-10-20", "09:15")
    assert lengths.picked({}, "end") == (None, None)


@pytest.mark.parametrize(("date_text", "time_text", "tz", "expected"), [
    (None, None, dt.UTC, None),
    ("2027-10-20", "09:15", dt.UTC, dt.datetime(2027, 10, 20, 9, 15, tzinfo=dt.UTC)),
    ("2027-10-20", "09:15", ATHENS, dt.datetime(2027, 10, 20, 6, 15, tzinfo=dt.UTC)),
    ("2027-10-20", None, dt.UTC, dt.datetime(2027, 10, 20, 23, 59, 59, tzinfo=dt.UTC)),
])
def test_end_at_combines_date_and_time_in_zone(date_text, time_text, tz, expected):
    assert lengths.end_at(date_text, time_text, tz) == expected


@pytest.mark.parametrize(("date_text", "time_text", "required", "message"), [
    (None, "09:00", False, "Select a date for the end time."),
    (None, None, True, "Select the end date."),
    (None, None, False, None),
    ("2027-10-15", None, False, "Select a time in the future."),
    ("2027-10-20", None, False, None),
])
def test_end_error_messages(date_text, time_text, required, message):
    at = lengths.end_at(date_text, time_text)

    assert lengths.end_error(date_text, time_text, at, required=required, now=NOW) == message


class Client:
    def __init__(self, tz="Europe/Athens", fails=False):
        self.tz = tz
        self.fails = fails

    def users_info(self, user):
        if self.fails:
            raise RuntimeError("ratelimited")
        return {"user": {"tz": self.tz}}


@pytest.fixture(autouse=True)
def clear_zone_cache(monkeypatch):
    monkeypatch.setattr(profile, "ZONE_CACHE", {})


def test_timezone_reads_the_members_zone_and_caches_it():
    assert profile.timezone(Client(), "U1") == ATHENS
    assert profile.timezone(Client(fails=True), "U1") == ATHENS


@pytest.mark.parametrize("client", [Client(tz="Nowhere/Land"), Client(tz=None), Client(fails=True)])
def test_timezone_falls_back_to_utc(client):
    assert profile.timezone(client, "U1") == dt.UTC


class App:
    def __init__(self):
        self.views = {}

    def action(self, key):
        return lambda fn: fn

    def view(self, key):
        def register(fn):
            self.views[key] = fn
            return fn
        return register


class Ack:
    def __init__(self):
        self.responses = []

    def __call__(self, **kwargs):
        self.responses.append(kwargs)


class Conn:
    def execute(self, sql, args=None):
        return self

    def fetchone(self):
        return None


def log_state(**picked):
    values = {
        action.TARGET: {action.TARGET: {"selected_user": "UTARGET"}},
        action.KIND: {action.KIND: {"selected_option": {"value": picked.pop("kind", "temp_ban")}}},
        action.REASON: {action.REASON: {"value": "spam"}},
    }
    if picked:
        values[action.UNTIL] = {action.UNTIL: {"selected_date": picked.get("date")},
                                action.UNTIL_TIME: {"selected_time": picked.get("time")}}
    else:
        values[action.UNTIL] = {action.UNTIL: {}, action.UNTIL_TIME: {}}
    blocks = [{"block_id": action.UNTIL}]
    return {"private_metadata": "49", "state": {"values": values}, "blocks": blocks}


def test_logging_a_temporary_ban_without_end_redraws_modal_with_end_error(monkeypatch):
    app = App()
    handlers.register(app)

    @contextlib.contextmanager
    def session():
        yield Conn()

    monkeypatch.setattr(handlers, "session", session)
    monkeypatch.setattr(memberguards, "guard_status", lambda *args: None)
    monkeypatch.setattr(profile, "timezone", lambda client, user_id: dt.UTC)
    ack = Ack()

    app.views[action.CALLBACK](ack, {"user": {"id": "UMOD"}}, log_state(), object())

    response = ack.responses[0]
    assert response["response_action"] == "update"
    labels = [block for block in response["view"]["blocks"] if block.get("block_id") == action.UNTIL]
    assert labels, "the end row stays in the redrawn modal"
    context_texts = [block["elements"][0]["text"] for block in response["view"]["blocks"] if block["type"] == "context"]
    assert "A temporary ban needs an end date." in context_texts
