import contextlib
import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from bot.core.formatting import short_end
from bot.nemo import channelguards, guards, profile, userbots
from bot.nemo.enforcement import slowmode
from bot.nemo.surface import thread_slowmode
from bot.nemo.views import slowmode as card

CHANNEL_ID = "C1"
THREAD = "1700000000.000000"
TS = "1700000000.000100"
USER_ID = "U1"
MOD = "UMOD"
NOW = dt.datetime(2027, 10, 16, 9, 30, tzinfo=dt.UTC)
END = dt.datetime(2027, 10, 17, 14, 30, tzinfo=dt.UTC)


def current(**over):
    row = {"id": 9, "seconds": 30, "expires_at": END, "reason": "Heated argument",
           "opened_by": MOD, "exempt": ["UEXEMPT"]}
    row.update(over)
    return row


def submission(**over):
    row = {"starting": True, "end_date": None, "end_time": None, "seconds": "30",
           "reason": "Heated argument", "exempt": []}
    row.update(over)
    return row


def block_ids(view):
    return [block.get("block_id") for block in view["blocks"]]


def end_row_elements(view):
    return next(block for block in view["blocks"] if block.get("block_id") == card.END)["elements"]


def test_build_view_new_has_empty_end_row_and_default_fields():
    view = card.build_view(CHANNEL_ID, THREAD)
    date_element, time_element = end_row_elements(view)

    assert block_ids(view) == [None, card.END, card.SECONDS, card.REASON, card.EXEMPT]
    assert view["blocks"][0]["text"]["text"] == "*End (UTC, optional)*"
    assert view["submit"]["text"] == "Enable"
    assert (date_element["type"], time_element["type"]) == ("datepicker", "timepicker")
    assert "initial_date" not in date_element and "initial_time" not in time_element
    assert card.is_extending(view) is False


def test_build_view_existing_shows_status_and_prefills_end_in_viewer_zone():
    view = card.build_view(CHANNEL_ID, THREAD, current(), ZoneInfo("Europe/Athens"), now=NOW)
    date_element, time_element = end_row_elements(view)

    assert block_ids(view) == [None, None, card.END, card.SECONDS, card.REASON, card.EXEMPT]
    assert view["submit"]["text"] == "Save"
    assert view["blocks"][0]["text"]["text"] == \
        f"*Enabled* until {short_end(END)} (1d 5h left), set by <@{MOD}>"
    assert view["blocks"][0]["accessory"]["action_id"] == card.DISABLE
    assert (date_element["initial_date"], time_element["initial_time"]) == ("2027-10-17", "17:30")
    assert view["blocks"][4]["element"]["initial_value"] == "Heated argument"
    assert view["blocks"][5]["element"]["initial_users"] == ["UEXEMPT"]
    assert card.is_extending(view) is True


def test_build_view_keeps_entered_values_and_shows_end_error():
    entered = submission(end_date="2027-10-20", end_time="09:00", seconds="45", reason="raid", exempt=["UA"])
    view = card.build_view(CHANNEL_ID, THREAD, values=entered, end_error="Select a time in the future.")
    date_element, time_element = end_row_elements(view)

    assert (date_element["initial_date"], time_element["initial_time"]) == ("2027-10-20", "09:00")
    assert view["blocks"][2]["elements"][0]["text"] == "Select a time in the future."
    assert view["blocks"][-3]["element"]["initial_value"] == "45"
    assert view["blocks"][-2]["element"]["initial_value"] == "raid"
    assert view["blocks"][-1]["element"]["initial_users"] == ["UA"]


def test_submitted_values_reads_end_row_and_fields():
    state = {"values": {
        card.END: {card.END + "_date": {"selected_date": "2027-10-20"}, card.END + "_time": {"selected_time": "09:15"}},
        card.SECONDS: {card.SECONDS: {"value": "45"}},
        card.REASON: {card.REASON: {"value": "  Heated argument "}},
        card.EXEMPT: {card.EXEMPT: {"selected_users": ["UEXEMPT"]}},
    }}

    assert card.submitted_values(state) == {
        "starting": True, "end_date": "2027-10-20", "end_time": "09:15", "seconds": "45",
        "reason": "Heated argument", "exempt": ["UEXEMPT"]}


def test_submitted_values_extending_view_is_not_starting():
    assert card.submitted_values({"values": {}}, extending=True)["starting"] is False


@pytest.mark.parametrize(("over", "errors"), [
    ({}, None),
    ({"end_date": "2027-10-20"}, None),
    ({"end_time": "09:00"}, {card.END: "Select a date for the end time."}),
    ({"end_date": "2027-10-15"}, {card.END: "Select a time in the future."}),
    ({"seconds": "0"}, {card.SECONDS: "Enter 1 to 3600 seconds."}),
    ({"seconds": "3601"}, {card.SECONDS: "Enter 1 to 3600 seconds."}),
    ({"seconds": "fast"}, {card.SECONDS: "Enter 1 to 3600 seconds."}),
    ({"reason": ""}, {card.REASON: "Add a reason."}),
])
def test_validation_errors_invalid_field_returns_block_error(over, errors):
    assert card.validation_errors(submission(**over), dt.UTC, NOW) == errors


@pytest.mark.parametrize(("over", "tz", "expected"), [
    ({}, dt.UTC, None),
    ({"end_date": "2027-10-17", "end_time": "14:30"}, dt.UTC, END),
    ({"end_date": "2027-10-17", "end_time": "17:30"}, ZoneInfo("Europe/Athens"), END),
])
def test_new_end_reads_picked_date_and_time_in_viewer_zone(over, tz, expected):
    assert card.new_end(submission(**over), tz) == expected


def test_notice_includes_cooldown_and_end():
    posted = card.notice(30, END)

    assert posted["text"] == f"*Slow mode enabled* with 30s cooldown until {short_end(END)}"
    assert len(posted["blocks"]) == 1


def test_removal_notice_in_thread_quotes_reply():
    notice = card.removal_notice(12, "my reply", in_thread=True)

    assert notice["text"] == "*Slow mode*: next reply in 12s"
    assert notice["blocks"][1]["elements"][0]["elements"][0]["text"] == "my reply"


def test_removal_notice_empty_body_has_no_quote_block():
    assert len(card.removal_notice(12, "", in_thread=False)["blocks"]) == 1


@pytest.fixture
def cache(monkeypatch):
    monkeypatch.setattr(channelguards, "_guards", {})
    monkeypatch.setattr(channelguards, "_loaded", True)
    monkeypatch.setattr(userbots, "_users", {})
    return channelguards._guards


def live(cache, thread_ts, guard_id, seconds, allowed=(), expires_at=None, threads=False):
    settings = {"seconds": seconds, **({"threads": True} if threads else {})}
    cache[(channelguards.SLOWMODE, CHANNEL_ID, thread_ts)] = channelguards.LiveGuard(
        guard_id, settings, frozenset(allowed), expires_at)


def test_thread_slowmode_lookup_is_separate_from_channel_active_guard(cache):
    live(cache, THREAD, 9, 30)

    assert channelguards.thread_slowmode(CHANNEL_ID, THREAD).guard_id == 9
    assert channelguards.active_guard(CHANNEL_ID, channelguards.SLOWMODE) is None
    assert channelguards.is_guarded(CHANNEL_ID) is True


def test_thread_slowmode_past_expiry_returns_none(cache):
    live(cache, THREAD, 9, 30, expires_at=dt.datetime.now(dt.UTC) - dt.timedelta(seconds=1))

    assert channelguards.thread_slowmode(CHANNEL_ID, THREAD) is None


def test_refresh_keys_guards_by_channel_and_thread(cache):
    rows = [("slowmode", CHANNEL_ID, "", 1, {"seconds": 60}, None, []),
            ("slowmode", CHANNEL_ID, THREAD, 2, {"seconds": 30}, END, ["UEXEMPT"])]

    class Conn:
        def execute(self, sql, args=None):
            return self

        def fetchall(self):
            return rows

    channelguards.refresh(Conn())

    assert set(channelguards._guards) == {("slowmode", CHANNEL_ID, ""), ("slowmode", CHANNEL_ID, THREAD)}
    assert channelguards._guards[("slowmode", CHANNEL_ID, THREAD)].expires_at == END


class Conn:
    def __init__(self, remaining=12):
        self.remaining = remaining
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        sql = self.executed[-1][0]
        if "INSERT INTO fd.slowmode_clock" in sql:
            return None
        if "FROM fd.slowmode_clock" in sql:
            return (self.remaining,)
        if "holds_capability" in sql:
            return (False,)
        return (1,)

    def args_for(self, mark):
        return [args for sql, args in self.executed if mark in sql]


class Slack:
    def __init__(self):
        self.ephemeral = []

    def chat_postEphemeral(self, **kwargs):
        self.ephemeral.append(kwargs)


class EventCtx:
    def __init__(self, event):
        self.payload = event
        self.client = Slack()


def reply(**over):
    return {"user": USER_ID, "channel": CHANNEL_ID, "ts": TS, "thread_ts": THREAD, "text": "my reply", **over}


@contextlib.contextmanager
def session_of(conn):
    yield conn


@pytest.fixture
def enforcing(monkeypatch, cache):
    conn = Conn()
    removed = []
    monkeypatch.setattr(slowmode, "session", lambda: session_of(conn))
    monkeypatch.setattr(slowmode.guard_actions, "remove",
                        lambda client, channel_id, ts: removed.append(ts) or True)
    monkeypatch.setattr(guards, "has_live_guard", lambda channel_id, thread_ts: False)
    return conn, removed


def test_on_message_thread_slowmode_fast_reply_is_removed_and_notified(enforcing, cache):
    conn, removed = enforcing
    live(cache, THREAD, 9, 30)
    ctx = EventCtx(reply())

    assert slowmode.on_message(ctx) is True
    assert removed == [TS]
    assert conn.args_for("INSERT INTO fd.slowmode_clock")[0][1] == THREAD
    assert conn.args_for("INSERT INTO fd.channel_guard_events")[0][0] == 9
    assert ctx.client.ephemeral[0]["text"] == "*Slow mode*: next reply in 12s"


def test_on_message_thread_slowmode_overrides_channel_slowmode(enforcing, cache):
    conn, _removed = enforcing
    live(cache, "", 1, 600, threads=True)
    live(cache, THREAD, 9, 30)

    slowmode.on_message(EventCtx(reply()))

    assert conn.args_for("INSERT INTO fd.slowmode_clock")[0][3] == 30
    assert conn.args_for("INSERT INTO fd.channel_guard_events")[0][0] == 9


def test_on_message_thread_slowmode_channel_message_returns_none(enforcing, cache):
    _conn, removed = enforcing
    live(cache, THREAD, 9, 30)

    assert slowmode.on_message(EventCtx(reply(thread_ts=None))) is None
    assert removed == []


def test_on_message_thread_slowmode_locked_thread_returns_none(enforcing, cache, monkeypatch):
    _conn, removed = enforcing
    live(cache, THREAD, 9, 30)
    monkeypatch.setattr(guards, "has_live_guard", lambda channel_id, thread_ts: True)

    assert slowmode.on_message(EventCtx(reply())) is None
    assert removed == []


def test_on_message_thread_slowmode_exempt_member_returns_none(enforcing, cache):
    _conn, removed = enforcing
    live(cache, THREAD, 9, 30, allowed=[USER_ID])

    assert slowmode.on_message(EventCtx(reply())) is None
    assert removed == []


class Client:
    def __init__(self, fails=False):
        self.fails = fails
        self.posted = []
        self.updated = []
        self.opened = []
        self.posted_ts = "1700000000.000700"

    def chat_postMessage(self, **kwargs):
        if self.fails:
            raise RuntimeError("not_in_channel")
        self.posted.append(kwargs)
        return {"ts": self.posted_ts}

    def views_update(self, **kwargs):
        self.updated.append(kwargs)

    def views_open(self, **kwargs):
        self.opened.append(kwargs)


class SurfaceCtx:
    def __init__(self, view, client=None):
        self.view = view
        self.client = client or Client()
        self.user_id = MOD
        self.channel_id = CHANNEL_ID
        self.thread_ts = THREAD
        self.trigger_id = "T1"
        self.ack_calls = []
        self.ephemerals = []

    def ack(self, **kwargs):
        self.ack_calls.append(kwargs)

    def join(self, channel_id=None):
        return None

    def post_ephemeral(self, message, channel_id=None, thread_ts=None):
        self.ephemerals.append(message)


def submitted_view(seconds="30", reason="Heated argument", end_date="2027-10-18", end_time="10:00",
                   extending=False):
    return {
        "id": "V1", "hash": "H1", "callback_id": card.CALLBACK,
        "private_metadata": card.metadata(CHANNEL_ID, THREAD, extend=extending),
        "state": {"values": {
            card.END: {card.END + "_date": {"selected_date": end_date}, card.END + "_time": {"selected_time": end_time}},
            card.SECONDS: {card.SECONDS: {"value": seconds}},
            card.REASON: {card.REASON: {"value": reason}},
            card.EXEMPT: {card.EXEMPT: {"selected_users": ["UEXEMPT"]}},
        }},
    }


@pytest.fixture
def guard_calls(monkeypatch):
    calls = {"opened": [], "updates": [], "allows": [], "lifted": [], "row": None, "notice_ts": []}
    monkeypatch.setattr(thread_slowmode, "session", lambda: session_of(object()))
    monkeypatch.setattr(channelguards, "slowmode_row", lambda conn, channel_id, thread_ts: calls["row"])
    monkeypatch.setattr(channelguards, "open_slowmode",
                        lambda conn, *args: calls["opened"].append(args) or 9)
    monkeypatch.setattr(channelguards, "update_slowmode",
                        lambda conn, row, *args: calls["updates"].append(args) or row["id"])
    monkeypatch.setattr(channelguards, "set_allows",
                        lambda conn, guard_id, ids, by: calls["allows"].append((guard_id, ids)))
    monkeypatch.setattr(channelguards, "lift", lambda conn, guard_id, by: calls["lifted"].append(guard_id) or CHANNEL_ID)
    monkeypatch.setattr(channelguards, "refresh", lambda conn: 0)
    monkeypatch.setattr(channelguards, "set_notice_ts",
                        lambda conn, guard_id, ts: calls["notice_ts"].append((guard_id, ts)))
    monkeypatch.setattr(profile, "timezone", lambda client, user_id: dt.UTC)
    return calls


def test_submit_slowmode_new_opens_guard_with_picked_end_and_posts_notice(guard_calls):
    ctx = SurfaceCtx(submitted_view())

    assert thread_slowmode.submit_slowmode(ctx) == 9
    (channel_id, thread_ts, seconds, by, reason, ends), = guard_calls["opened"]
    assert (channel_id, thread_ts, seconds, by, reason) == (CHANNEL_ID, THREAD, 30, MOD, "Heated argument")
    assert ends == dt.datetime(2027, 10, 18, 10, 0, tzinfo=dt.UTC)
    assert guard_calls["allows"] == [(9, ["UEXEMPT"])]
    assert ctx.client.posted[0]["text"] == f"*Slow mode enabled* with 30s cooldown until {short_end(ends)}"
    assert guard_calls["notice_ts"] == [(9, ctx.client.posted_ts)]
    assert ctx.ephemerals == []


def test_submit_slowmode_new_without_end_has_no_end_date(guard_calls):
    ctx = SurfaceCtx(submitted_view(end_date=None, end_time=None))

    thread_slowmode.submit_slowmode(ctx)

    assert guard_calls["opened"][0][-1] is None


def test_submit_slowmode_existing_updates_end_without_notice(guard_calls):
    guard_calls["row"] = current()
    ctx = SurfaceCtx(submitted_view(seconds="60", extending=True))

    thread_slowmode.submit_slowmode(ctx)

    assert guard_calls["updates"] == [
        (60, MOD, "Heated argument", dt.datetime(2027, 10, 18, 10, 0, tzinfo=dt.UTC))]
    assert ctx.client.posted == []
    assert ctx.ephemerals == []


def test_submit_slowmode_ended_guard_returns_none_with_message(guard_calls):
    ctx = SurfaceCtx(submitted_view(extending=True))

    assert thread_slowmode.submit_slowmode(ctx) is None
    assert guard_calls["opened"] == []
    assert ctx.ephemerals == ["Slow mode already ended"]


def test_submit_slowmode_past_end_redraws_modal_with_error(guard_calls):
    ctx = SurfaceCtx(submitted_view(end_date="2020-01-01"))

    thread_slowmode.submit_slowmode(ctx)

    assert guard_calls["opened"] == []
    assert ctx.ack_calls[0]["response_action"] == "update"
    assert ctx.ack_calls[0]["view"]["blocks"][2]["elements"][0]["text"] == "Select a time in the future."


def test_submit_slowmode_notice_failure_lifts_guard(guard_calls):
    ctx = SurfaceCtx(submitted_view(), Client(fails=True))

    assert thread_slowmode.submit_slowmode(ctx) is None
    assert guard_calls["lifted"] == [9]
    assert ctx.ephemerals == ["Slow mode not enabled: Nemo could not post in this thread (RuntimeError)"]


def test_submit_slowmode_invalid_cooldown_acks_errors(guard_calls):
    ctx = SurfaceCtx(submitted_view(seconds="0"))

    thread_slowmode.submit_slowmode(ctx)

    assert ctx.ack_calls == [{"response_action": "errors", "errors": {card.SECONDS: "Enter 1 to 3600 seconds."}}]
    assert guard_calls["opened"] == []


def test_disable_slowmode_lifts_guard_and_updates_view(guard_calls):
    guard_calls["row"] = current()
    ctx = SurfaceCtx(submitted_view())

    assert thread_slowmode.disable_slowmode(ctx) == 9
    assert guard_calls["lifted"] == [9]
    assert ctx.client.updated[0]["view"]["callback_id"] == card.DISABLED_CALLBACK
    assert ctx.ephemerals == ["Slow mode disabled"]


def test_open_slowmode_modal_existing_guard_shows_save_button(guard_calls):
    guard_calls["row"] = current()
    ctx = SurfaceCtx({})

    thread_slowmode.open_slowmode_modal(ctx)

    assert ctx.client.opened[0]["view"]["submit"]["text"] == "Save"


class NoticeConn:
    def __init__(self, claimed):
        self.claimed = claimed
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchall(self):
        return self.claimed

    def args_for(self, sql):
        return [args for one, args in self.executed if one == sql]


class Poster:
    def __init__(self, fails=False):
        self.fails = fails
        self.posted = []

    def chat_postMessage(self, **kwargs):
        if self.fails:
            raise RuntimeError("not_in_channel")
        self.posted.append(kwargs)
        return {"ts": "1700000000.000900"}


def claimed_notice(attempts=1, thread_ts=""):
    return (5, CHANNEL_ID, thread_ts, {"seconds": 30}, None, MOD, attempts)


def test_post_notices_posts_in_channel_and_records_ts(monkeypatch):
    conn = NoticeConn([claimed_notice()])
    monkeypatch.setattr(slowmode, "session", lambda: session_of(conn))
    client = Poster()

    assert slowmode.post_notices(client) == 1
    assert client.posted[0]["channel"] == CHANNEL_ID
    assert client.posted[0]["thread_ts"] is None
    assert client.posted[0]["text"] == "*Slow mode enabled* with 30s cooldown with no end date"
    assert conn.args_for(slowmode.NOTICE_POSTED) == [("1700000000.000900", 5)]


@pytest.mark.parametrize(("attempts", "again"), [(1, True), (2, True), (3, False)])
def test_post_notices_failure_requeues_below_three_attempts(monkeypatch, attempts, again):
    conn = NoticeConn([claimed_notice(attempts=attempts)])
    monkeypatch.setattr(slowmode, "session", lambda: session_of(conn))

    assert slowmode.post_notices(Poster(fails=True)) == 0
    assert bool(conn.args_for(slowmode.NOTICE_AGAIN)) is again
    assert conn.args_for(slowmode.NOTICE_POSTED) == []


def test_claim_notices_selects_live_guards_with_notice_wanted():
    assert "WHERE notice_wanted AND state = 'live'" in slowmode.CLAIM_NOTICES
    assert "FOR UPDATE SKIP LOCKED" in slowmode.CLAIM_NOTICES


@pytest.mark.parametrize(("over", "row", "expected"), [
    ({}, None, None),
    ({"starting": False}, current(), END),
    ({"starting": False, "end_date": "2027-10-19", "end_time": "08:00"}, current(),
     dt.datetime(2027, 10, 19, 8, 0, tzinfo=dt.UTC)),
    ({"starting": False, "end_date": "2027-10-16", "end_time": "08:00"}, current(),
     dt.datetime(2027, 10, 16, 8, 0, tzinfo=dt.UTC)),
    ({"starting": False}, current(expires_at=None), None),
])
def test_new_end_keeps_current_end_when_editing_with_no_pick(over, row, expected):
    assert card.new_end(submission(**over), dt.UTC, row) == expected


def test_submit_slowmode_existing_without_pick_keeps_the_end(guard_calls):
    guard_calls["row"] = current()
    ctx = SurfaceCtx(submitted_view(end_date=None, end_time=None, extending=True))

    thread_slowmode.submit_slowmode(ctx)

    assert guard_calls["updates"][0][-1] == END


class NoticeSyncConn:
    def __init__(self, stale=(), ended=()):
        self.rows = {slowmode.CLAIM_STALE_NOTICES: list(stale), slowmode.CLAIM_ENDED_NOTICES: list(ended)}
        self.executed = []
        self.last = None

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        self.last = sql
        return self

    def fetchall(self):
        return self.rows.get(self.last, [])

    def args_for(self, sql):
        return [args for one, args in self.executed if one == sql]


class Editor:
    def __init__(self, update_error=None, delete_error=None):
        self.update_error = update_error
        self.delete_error = delete_error
        self.updates = []
        self.deletes = []

    def chat_update(self, **kwargs):
        if self.update_error:
            raise RuntimeError(self.update_error)
        self.updates.append(kwargs)

    def chat_delete(self, **kwargs):
        if self.delete_error:
            raise RuntimeError(self.delete_error)
        self.deletes.append(kwargs)


def test_refresh_notices_edits_the_posted_notice_with_current_settings(monkeypatch):
    conn = NoticeSyncConn(stale=[(5, CHANNEL_ID, {"seconds": 45}, END, "1700000000.000900")])
    monkeypatch.setattr(slowmode, "session", lambda: session_of(conn))
    client = Editor()

    assert slowmode.refresh_notices(client) == 1
    assert client.updates[0]["ts"] == "1700000000.000900"
    assert client.updates[0]["text"] == f"*Slow mode enabled* with 45s cooldown until {short_end(END)}"


def test_refresh_notices_failure_is_skipped(monkeypatch):
    conn = NoticeSyncConn(stale=[(5, CHANNEL_ID, {"seconds": 45}, END, "1700000000.000900")])
    monkeypatch.setattr(slowmode, "session", lambda: session_of(conn))

    assert slowmode.refresh_notices(Editor(update_error="message_not_found")) == 0


def test_remove_ended_notices_deletes_the_notice_message(monkeypatch):
    conn = NoticeSyncConn(ended=[(5, CHANNEL_ID, "1700000000.000900")])
    monkeypatch.setattr(slowmode, "session", lambda: session_of(conn))
    client = Editor()

    assert slowmode.remove_ended_notices(client) == 1
    assert client.deletes == [{"channel": CHANNEL_ID, "ts": "1700000000.000900"}]


@pytest.mark.parametrize(("error", "removed", "released"), [
    ("message_not_found", 1, False), ("channel_not_found", 1, False), ("ratelimited", 0, True)])
def test_remove_ended_notices_releases_the_claim_only_on_retryable_errors(monkeypatch, error, removed, released):
    conn = NoticeSyncConn(ended=[(5, CHANNEL_ID, "1700000000.000900")])
    monkeypatch.setattr(slowmode, "session", lambda: session_of(conn))

    assert slowmode.remove_ended_notices(Editor(delete_error=error)) == removed
    assert bool(conn.args_for(slowmode.RELEASE_ENDED_NOTICE)) is released


def test_sync_notices_runs_post_refresh_and_remove(monkeypatch):
    monkeypatch.setattr(slowmode, "post_notices", lambda client: 1)
    monkeypatch.setattr(slowmode, "refresh_notices", lambda client: 2)
    monkeypatch.setattr(slowmode, "remove_ended_notices", lambda client: 4)

    assert slowmode.sync_notices(object()) == 7
