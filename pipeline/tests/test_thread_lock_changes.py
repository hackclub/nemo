import contextlib
import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from bot.core.formatting import short_end
from bot.nemo import guard_actions, guards, profile
from bot.nemo.surface import thread_destroy, thread_lock
from bot.nemo.views import guard as card

CHANNEL_ID = "C1"
THREAD = "1700000000.000000"
MOD = "UMOD"
NOW = dt.datetime(2027, 10, 16, 9, 30, tzinfo=dt.UTC)
END = dt.datetime(2027, 10, 17, 14, 30, tzinfo=dt.UTC)


def lock_row(**over):
    row = {"id": 5, "kind": guards.LOCK, "opened_by": MOD, "expires_at": END, "reason": "Heated argument",
           "warned_ts": "1700000000.000500"}
    row.update(over)
    return row


ATHENS = ZoneInfo("Europe/Athens")


def values(**over):
    row = {"reason": "Heated argument", "starting": True, "end_date": None, "end_time": None,
           "note": False, "note_body": None}
    row.update(over)
    return row


def block_ids(view):
    return [block.get("block_id") for block in view["blocks"]]


def end_row_elements(view):
    return next(block for block in view["blocks"] if block.get("block_id") == card.END)["elements"]


def test_lock_view_has_end_row_and_reason_blocks():
    view = card.lock_view(CHANNEL_ID, THREAD)

    assert block_ids(view) == [None, card.END, card.REASON]
    assert [one["type"] for one in end_row_elements(view)] == ["datepicker", "timepicker"]
    assert view["blocks"][0]["text"]["text"] == "*End, optional*"
    assert view["submit"]["text"] == "Lock"
    assert card.is_extending(view) is False


def test_lock_view_keeps_entered_values_and_shows_end_error():
    view = card.lock_view(CHANNEL_ID, THREAD, values(end_date="2027-10-20", end_time="09:00"),
                          end_error="Select a time in the future.")

    date_element, time_element = end_row_elements(view)
    assert (date_element["initial_date"], time_element["initial_time"]) == ("2027-10-20", "09:00")
    assert view["blocks"][2]["elements"][0]["text"] == "Select a time in the future."
    assert view["blocks"][-1]["element"]["initial_value"] == "Heated argument"


def test_locked_view_shows_status_and_prefills_current_end_in_viewer_zone():
    view = card.locked_view(CHANNEL_ID, THREAD, lock_row(), ATHENS, now=NOW)

    assert view["blocks"][0]["text"]["text"] == (
        f"*Locked* until {short_end(END)} (1d 5h left) for *Heated argument*, set by <@{MOD}>")
    assert view["blocks"][0]["accessory"]["action_id"] == card.UNLOCK
    assert view["blocks"][1]["text"]["text"] == "*New end*"
    date_element, time_element = end_row_elements(view)
    assert (date_element["initial_date"], time_element["initial_time"]) == ("2027-10-17", "17:30")
    assert view["submit"]["text"] == "Save"
    assert card.is_extending(view) is True


def test_locked_view_prefers_entered_end_over_current_end():
    view = card.locked_view(CHANNEL_ID, THREAD, lock_row(), ATHENS, values(end_date="2027-10-25", end_time="08:00"))

    date_element, time_element = end_row_elements(view)
    assert (date_element["initial_date"], time_element["initial_time"]) == ("2027-10-25", "08:00")


def test_submitted_values_reads_end_row_and_reason():
    state = {"values": {
        card.END: {card.END + "_date": {"selected_date": "2027-10-20"}, card.END + "_time": {"selected_time": "09:15"}},
        card.REASON: {card.REASON: {"value": " raid "}},
    }}

    picked = card.submitted_values(state)

    assert (picked["starting"], picked["end_date"], picked["end_time"], picked["reason"]) == (
        True, "2027-10-20", "09:15", "raid")
    assert card.submitted_values(state, extending=True)["starting"] is False


@pytest.mark.parametrize(("over", "errors"), [
    ({}, None),
    ({"end_date": "2027-10-20"}, None),
    ({"reason": ""}, {card.REASON: "Add a reason."}),
    ({"end_time": "09:00"}, {card.END: "Select a date for the end time."}),
    ({"end_date": "2027-10-15"}, {card.END: "Select a time in the future."}),
    ({"starting": False, "reason": ""}, {card.END: "Select the end date."}),
    ({"starting": False, "reason": "", "end_date": "2027-10-20"}, None),
])
def test_lock_errors_validates_reason_and_end(over, errors):
    assert card.lock_errors(values(**over), dt.UTC, NOW) == errors


def test_lock_errors_extend_accepts_earlier_and_later_ends_but_not_the_past():
    earlier = values(starting=False, end_date="2027-10-17", end_time="10:00")
    later = values(starting=False, end_date="2027-10-18", end_time="10:00")
    past = values(starting=False, end_date="2027-10-15", end_time="10:00")

    assert card.lock_errors(earlier, dt.UTC, NOW) is None
    assert card.lock_errors(later, dt.UTC, NOW) is None
    assert card.lock_errors(past, dt.UTC, NOW) == {card.END: "Select a time in the future."}


@pytest.mark.parametrize(("over", "tz", "expected"), [
    ({}, dt.UTC, None),
    ({"end_date": "2027-10-17", "end_time": "14:30"}, dt.UTC, END),
    ({"end_date": "2027-10-17", "end_time": "17:30"}, ATHENS, END),
    ({"end_date": "2027-10-17"}, dt.UTC, dt.datetime(2027, 10, 17, 23, 59, 59, tzinfo=dt.UTC)),
])
def test_lock_end_reads_picked_date_and_time_in_viewer_zone(over, tz, expected):
    assert card.lock_end(values(**over), tz) == expected


class Client:
    def __init__(self, delete_error=None):
        self.delete_error = delete_error
        self.opened = []
        self.updated = []
        self.deleted = []

    def views_open(self, **kwargs):
        self.opened.append(kwargs)

    def views_update(self, **kwargs):
        self.updated.append(kwargs)

    def chat_delete(self, **kwargs):
        if self.delete_error:
            raise RuntimeError(self.delete_error)
        self.deleted.append(kwargs)


class SurfaceCtx:
    def __init__(self, view=None, client=None, body=None):
        self.view = view or {}
        self.body = body or {}
        self.client = client or Client()
        self.user_id = MOD
        self.channel_id = CHANNEL_ID
        self.thread_ts = THREAD
        self.trigger_id = "T1"
        self.acked = []
        self.ephemeral_messages = []

    def ack(self, **kwargs):
        self.acked.append(kwargs)

    def join(self, channel_id=None):
        return None

    def post_ephemeral(self, message, channel_id=None, thread_ts=None):
        self.ephemeral_messages.append(message)


@contextlib.contextmanager
def session_of(conn=None):
    yield conn


def locked_submission(end_date="2027-10-18", end_time="14:30"):
    view = card.locked_view(CHANNEL_ID, THREAD, lock_row())
    view.update(id="V1", hash="H1")
    view["state"] = {"values": {card.END: {
        card.END + "_date": {"selected_date": end_date}, card.END + "_time": {"selected_time": end_time}}}}
    return view


@pytest.fixture
def live(monkeypatch):
    state = {"row": lock_row(), "extended": [], "lifted": []}
    monkeypatch.setattr(thread_lock, "session", lambda: session_of(object()))
    monkeypatch.setattr(guards, "live_on_thread", lambda conn, channel_id, thread_ts: state["row"])
    monkeypatch.setattr(guards, "extend",
                        lambda conn, current, expires_at, by: state["extended"].append((current["id"], expires_at, by))
                        or current["id"])
    monkeypatch.setattr(guards, "refresh", lambda conn: 0)
    monkeypatch.setattr(guard_actions, "lift_lock",
                        lambda client, guard_id, by=None: state["lifted"].append((guard_id, by)) or guard_id)
    monkeypatch.setattr(guard_actions, "update_lock_notice", lambda client, guard_id: None)
    monkeypatch.setattr(profile, "timezone", lambda client, user_id: dt.UTC)
    return state


def test_open_lock_modal_locked_thread_shows_status_view(live):
    ctx = SurfaceCtx()

    thread_lock.open_lock_modal(ctx)

    assert ctx.client.opened[0]["view"]["submit"]["text"] == "Save"


def test_open_lock_modal_destroying_thread_refuses(live):
    live["row"] = lock_row(kind=guards.DESTROY)
    ctx = SurfaceCtx()

    thread_lock.open_lock_modal(ctx)

    assert ctx.client.opened == []
    assert ctx.ephemeral_messages == ["Thread already being destroyed"]


def test_unlock_thread_lifts_lock_and_updates_view(live):
    ctx = SurfaceCtx(locked_submission())

    assert thread_lock.unlock_thread(ctx) == 5
    assert live["lifted"] == [(5, MOD)]
    assert ctx.client.updated[0]["view"]["callback_id"] == card.UNLOCKED_CALLBACK
    assert ctx.ephemeral_messages == ["Thread unlocked"]


def notice_click(value=card.NOTICE_UNLOCK):
    return {"actions": [{"action_id": card.NOTICE_MENU, "selected_option": {"value": value}}]}


def test_unlock_from_notice_lifts_lock_and_confirms_to_clicker(live):
    ctx = SurfaceCtx(body=notice_click())

    assert thread_lock.unlock_from_notice(ctx) == 5
    assert live["lifted"] == [(5, MOD)]
    assert ctx.ephemeral_messages == ["Thread unlocked"]


def test_unlock_from_notice_after_lock_ended_reports_ended(live):
    live["row"] = None
    ctx = SurfaceCtx(body=notice_click())

    assert thread_lock.unlock_from_notice(ctx) is None
    assert live["lifted"] == []
    assert ctx.ephemeral_messages == ["Lock already ended"]


def test_unlock_from_notice_unknown_option_does_nothing(live):
    ctx = SurfaceCtx(body=notice_click("other"))

    assert thread_lock.unlock_from_notice(ctx) is None
    assert live["lifted"] == []
    assert ctx.ephemeral_messages == []


def test_submit_lock_extend_moves_end_to_picked_time(live):
    ctx = SurfaceCtx(locked_submission("2027-10-18", "16:30"))

    thread_lock.submit_lock(ctx)

    assert live["extended"] == [(5, dt.datetime(2027, 10, 18, 16, 30, tzinfo=dt.UTC), MOD)]
    assert ctx.acked == [{}]
    assert ctx.ephemeral_messages == []


def test_submit_lock_extend_after_lock_ended_is_refused(live):
    live["row"] = None
    ctx = SurfaceCtx(locked_submission())

    thread_lock.submit_lock(ctx)

    assert live["extended"] == []
    assert ctx.ephemeral_messages == ["Lock already ended"]


def test_submit_lock_extend_without_date_redraws_modal_with_error(live):
    ctx = SurfaceCtx(locked_submission(None, None))

    thread_lock.submit_lock(ctx)

    assert live["extended"] == []
    assert ctx.acked[0]["response_action"] == "update"
    assert ctx.acked[0]["view"]["blocks"][3]["elements"][0]["text"] == "Select the end date."


def test_submit_lock_extend_can_move_the_end_earlier(live):
    ctx = SurfaceCtx(locked_submission("2027-10-17", "10:00"))

    thread_lock.submit_lock(ctx)

    assert live["extended"] == [(5, dt.datetime(2027, 10, 17, 10, 0, tzinfo=dt.UTC), MOD)]


def test_submit_lock_extend_in_the_past_redraws_modal_with_error(live):
    ctx = SurfaceCtx(locked_submission("2020-01-01", "10:00"))

    thread_lock.submit_lock(ctx)

    assert live["extended"] == []
    assert ctx.acked[0]["view"]["blocks"][3]["elements"][0]["text"] == "Select a time in the future."


def test_submit_lock_start_with_missing_reason_acks_input_error(live):
    live["row"] = None
    view = card.lock_view(CHANNEL_ID, THREAD)
    view.update(id="V1", hash="H1")
    view["state"] = {"values": {card.REASON: {card.REASON: {"value": ""}}}}
    ctx = SurfaceCtx(view)

    thread_lock.submit_lock(ctx)

    assert ctx.acked == [{"response_action": "errors", "errors": {card.REASON: "Add a reason."}}]


class WarningConn:
    def __init__(self, waiting):
        self.waiting = waiting
        self.removed = []

    def execute(self, sql, args=None):
        if sql == guards.WARNING_REMOVED:
            self.removed.append(args[0])
        return self

    def fetchall(self):
        return self.waiting


@pytest.mark.parametrize(("error", "removed"), [(None, [5]), ("message_not_found", [5]),
                                                ("channel_not_found", [5]), ("ratelimited", [])])
def test_remove_lock_warnings_delete_error_controls_removed_ids(monkeypatch, error, removed):
    conn = WarningConn([(5, CHANNEL_ID, THREAD, "1700000000.000500")])
    monkeypatch.setattr(guard_actions, "session", lambda: session_of(conn))
    client = Client(delete_error=error)

    guard_actions.remove_lock_warnings(client)

    assert conn.removed == removed


def test_warnings_to_remove_sql_selects_ended_locks_with_notice():
    assert "kind = 'lock' AND state IN ('done', 'failed') AND warned_ts IS NOT NULL" in guards.WARNINGS_TO_REMOVE
    assert "warning_removed_at IS NULL" in guards.WARNINGS_TO_REMOVE


def test_destroy_thread_on_locked_thread_finishes_lock_then_opens_destroy(monkeypatch):
    calls = []
    monkeypatch.setattr(thread_destroy, "session", lambda: session_of(object()))
    monkeypatch.setattr(guards, "live_on_thread", lambda conn, channel_id, thread_ts: lock_row())
    monkeypatch.setattr(guards, "finish",
                        lambda conn, guard_id, state, error=None, sha=None, by=None:
                        calls.append(("finish", guard_id, state, by)))
    monkeypatch.setattr(guards, "open_guard", lambda conn, kind, *args: calls.append(("open", kind)) or 6)
    monkeypatch.setattr(guards, "warn", lambda *args: "1.1")
    monkeypatch.setattr(guards, "refresh", lambda conn: 0)
    view = card.destroy_view(CHANNEL_ID, THREAD)
    view["state"] = {"values": {card.REASON: {card.REASON: {"value": "raid"}}}}

    assert thread_destroy.destroy_thread(SurfaceCtx(view)) == 6
    assert calls == [("finish", 5, "done", MOD), ("open", guards.DESTROY)]
