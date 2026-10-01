import datetime as dt

import pytest
from slack_sdk.errors import SlackApiError

from bot.core import access
from bot.nemo import activity, surface
from bot.nemo.cards import activity as card
from bot.nemo.surface import message_activity

ROOM = "C0ANNOUNCE"
TS = "1790701062.123456"
ME = "U0ME"
THEM = "U0THEM"

STATS = {
    "num_users_viewed": 224,
    "num_users_clicked": 58,
    "num_users_reacted": 12,
    "num_shares": 0,
    "top_threaded_reply_by_reactions_ts": "1790701348.867479",
    "viewers_time_series": {
        "data": [
            {"seriesType": "1h", "series": [
                {"value": 1790701062000000, "count": 0},
                {"value": 1790701122000000, "count": 3},
            ]},
            {"seriesType": "1d", "series": [
                {"value": 1790701062000000, "count": 0},
                {"value": 1790701962000000, "count": 23},
                {"value": 1790702862000000, "count": 14},
            ]},
        ]
    },
    "client_breakdown": {"desktop_count": 75, "browser_count": 123, "mobile_count": 26},
}


def test_the_numbers_are_lifted_off_the_answer():
    said = activity.shaped(STATS)
    assert (said["viewers"], said["reacted"], said["clicked"], said["shared"]) == (224, 12, 58, 0)
    assert said["top_reply_ts"] == "1790701348.867479"


def test_the_client_split_is_shares_of_the_whole():
    said = activity.shaped(STATS)
    assert said["clients"] == [("browser", 123, 55), ("desktop", 75, 33), ("mobile", 26, 12)]


def test_a_curve_is_utc_stamps_and_new_viewers_per_bucket():
    said = activity.shaped(STATS)
    hour = said["curves"]["1h"]
    assert hour[0] == (dt.datetime(2026, 9, 29, 16, 57, 42, tzinfo=dt.UTC), 0)
    assert hour[1][1] == 3
    assert said["curves"]["30d"] == [], "a span slack did not send is empty, not missing"


def test_an_empty_answer_shapes_to_zeros():
    said = activity.shaped({})
    assert said["viewers"] == 0
    assert said["clients"] == [("browser", 0, None), ("desktop", 0, None), ("mobile", 0, None)]


class Conn:
    def __init__(self, rows=None):
        self.rows = rows or {}
        self.ran = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def fetchone(self):
        for mark, row in self.rows.items():
            if mark in self.ran[-1][0]:
                return row
        return None

    def fetchall(self):
        return []


def test_only_the_author_reads_their_post():
    assert activity.may_read(ME, ME) is True
    assert activity.may_read(THEM, ME) is False
    assert activity.may_read(ME, None) is False, "a post with no author is nobody's"


def test_an_every_account_capability_needs_no_fire_department_grant():
    conn = Conn(rows={"FROM app.capability": ("See how their own post did", "author", True)})
    assert access.may(conn, ME, "message.read") == (True, None)
    assert not any("effective_role" in sql for sql, _ in conn.ran), "no role lookup was needed"


def test_a_capability_that_is_not_every_account_still_wants_a_grant():
    conn = Conn(rows={"FROM app.capability": ("Read every case", None, False),
                      "holds_capability": (False,)})
    allowed, why = access.may(conn, ME, "case.read")
    assert allowed is False
    assert "grant" in why


def test_the_card_quotes_the_post_and_says_who_where_when():
    said = activity.shaped(STATS)
    view = card.view(ROOM, TS, ME, "hello  world", said, found=None, crowd=600)
    blocks = view["blocks"]
    assert blocks[0]["text"]["text"] == "> hello world"
    assert f"<@{ME}>" in blocks[1]["elements"][0]["text"]
    assert f"<#{ROOM}>" in blocks[1]["elements"][0]["text"]
    fields = [one["text"] for one in blocks[3]["fields"]]
    assert fields[0] == "*Viewers*\n224 · 37% of the channel"
    assert fields[4] == "*Replies*\nnot landed yet"
    assert blocks[4]["elements"][0]["text"] == "55% browser · 33% desktop · 12% mobile"
    assert blocks[5]["elements"][0]["text"] == "3 viewers in the first hour, 37 in the first day"
    buttons = next(one for one in blocks if one["type"] == "actions")["elements"]
    assert [one["action_id"] for one in buttons] == [card.OPEN_TOP_REPLY]
    assert buttons[0]["url"] == (
        "https://hackclub.slack.com/archives/C0ANNOUNCE/p1790701348867479"
        "?thread_ts=1790701062.123456&cid=C0ANNOUNCE"
    )


def test_a_long_post_is_cut_short_in_the_card():
    view = card.view(ROOM, TS, ME, "x" * 1000, activity.shaped({}))
    assert len(view["blocks"][0]["text"]["text"]) <= card.QUOTE_LIMIT + 2


def test_replies_read_off_the_archive_row():
    assert card.replies_line({"reply_count": 8, "reply_users_count": 1}) == "8 from 1 person"
    assert card.replies_line({"reply_count": 0, "reply_users_count": 0}) == "none"


class Answer:
    """What the slack sdk hands back: not a dict, but it reads like one"""

    def __init__(self, data):
        self.data = data

    def __getitem__(self, key):
        return self.data[key]

    def get(self, key, fallback=None):
        return self.data.get(key, fallback)


class Slack:
    def __init__(self, refuses_the_file=0):
        self.opened = []
        self.updated = []
        self.ephemeral = []
        self.refuses_the_file = refuses_the_file

    def views_open(self, **asked):
        self.opened.append(asked)
        return Answer({"view": {"id": "V1"}})

    def views_update(self, **asked):
        self.updated.append(asked)
        if self.refuses_the_file > 0:
            self.refuses_the_file -= 1
            raise SlackApiError(
                "invalid_arguments: [ERROR] invalid slack file "
                "[json-pointer:view/blocks/5/slack_file.id/slack_file]",
                Answer({"ok": False, "error": "invalid_arguments"}),
            )
        return Answer({"ok": True})

    def chat_postEphemeral(self, **asked):
        self.ephemeral.append(asked)


class _Session:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self.conn

    def __exit__(self, *_):
        return False


def clicked(author=ME, who=ME, thread_ts=None):
    message = {"ts": TS, "user": author, "text": "big news"}
    if thread_ts:
        message["thread_ts"] = thread_ts
    body = {"user": {"id": who}, "channel": {"id": ROOM}, "trigger_id": "T1", "message": message}
    entry = surface.Entry(surface.SHORTCUT, message_activity.SHORTCUT, "message.read", None)
    return surface.Ctx(entry, body, Slack(), lambda: None)


def hold(monkeypatch, shown=True, stats=None, landed=None):
    rows = {}
    if shown:
        rows["app.channel_message_activity"] = (1,)
    if landed:
        rows["FROM archive.message"] = landed
    conn = Conn(rows=rows)
    monkeypatch.setattr(message_activity, "session", lambda: _Session(conn))
    monkeypatch.setattr(activity, "fetch", lambda channel_id, ts: stats)
    return conn


def test_a_reply_is_turned_away_before_anything_is_read(monkeypatch):
    conn = hold(monkeypatch)
    ctx = clicked(thread_ts="1790700000.000001")
    message_activity.asked(ctx)
    assert ctx.client.ephemeral[0]["text"] == message_activity.NOT_A_POST
    assert conn.ran == []


def test_a_channel_that_is_not_shown_says_so(monkeypatch):
    hold(monkeypatch, shown=False)
    ctx = clicked()
    message_activity.asked(ctx)
    assert ctx.client.ephemeral[0]["text"] == message_activity.NOT_SHOWN
    assert ctx.client.opened == []


def test_somebody_elses_post_is_refused_and_written_down(monkeypatch):
    conn = hold(monkeypatch)
    ctx = clicked(author=THEM, who=ME)
    message_activity.asked(ctx)
    assert ctx.client.ephemeral[0]["text"] == message_activity.NOT_YOURS
    refusals = [args for sql, args in conn.ran if "fd.audit" in sql]
    assert len(refusals) == 1
    assert ctx.client.opened == []


def test_the_author_gets_a_modal_that_fills_in_once_slack_answers(monkeypatch):
    hold(monkeypatch, stats=activity.shaped(STATS), landed=(8, 5, None))
    ctx = clicked()
    message_activity.asked(ctx)
    assert ctx.client.opened[0]["view"] == card.reading()
    filled = ctx.client.updated[0]
    assert filled["view_id"] == "V1"
    assert filled["view"]["title"]["text"] == card.TITLE
    fields = [one["text"] for one in filled["view"]["blocks"][3]["fields"]]
    assert fields[4] == "*Replies*\n8 from 5 people"


def test_a_chart_slack_has_not_finished_taking_is_tried_again(monkeypatch):
    hold(monkeypatch, stats=activity.shaped(STATS), landed=(8, 5, None))
    monkeypatch.setattr(activity, "chart", lambda *said: ("F1", "1d"))
    ctx = clicked()
    ctx.client.refuses_the_file = 1
    monkeypatch.setattr(message_activity.time, "sleep", lambda _: None)

    message_activity.asked(ctx)

    assert len(ctx.client.updated) == 2, "it waits and puts the same card up again"
    assert ctx.client.updated[1]["view"] == ctx.client.updated[0]["view"]
    assert any(one["type"] == "image" for one in ctx.client.updated[1]["view"]["blocks"])


def test_a_chart_slack_keeps_refusing_leaves_the_numbers_standing(monkeypatch):
    hold(monkeypatch, stats=activity.shaped(STATS), landed=(8, 5, None))
    monkeypatch.setattr(activity, "chart", lambda *said: ("F1", "1d"))
    ctx = clicked()
    ctx.client.refuses_the_file = message_activity.FILE_TRIES
    monkeypatch.setattr(message_activity.time, "sleep", lambda _: None)

    message_activity.asked(ctx)

    last = ctx.client.updated[-1]["view"]
    assert not any(one["type"] == "image" for one in last["blocks"]), "the chart is dropped"
    assert last["title"]["text"] == card.TITLE, "the numbers still fill the modal in"


def test_when_slack_will_not_answer_the_modal_says_so(monkeypatch):
    hold(monkeypatch, stats=None)
    ctx = clicked()
    message_activity.asked(ctx)
    assert ctx.client.updated[0]["view"] == card.sorry(message_activity.NOT_NOW)


def test_the_shortcut_is_registered_behind_message_read():
    from bot.nemo import app as nemo_app  # noqa: F401  registers every surface

    found = [one for one in surface.ENTRIES
             if (one.kind, one.key) == (surface.SHORTCUT, message_activity.SHORTCUT)]
    assert found and found[0].needs == "message.read"


@pytest.mark.parametrize("key", ["message.read", "message.show"])
def test_the_new_capabilities_are_in_the_catalogue(key):
    from lib import capabilities

    assert key in capabilities.capabilities()



def test_a_curve_renders_to_a_png_of_the_right_size():
    import io

    from PIL import Image

    from bot.nemo import plot

    said = activity.shaped(STATS)
    png = plot.render(said["curves"]["1d"], "1d", viewers=said["viewers"])
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    assert Image.open(io.BytesIO(png)).size == (plot.WIDE, plot.HIGH)


def test_a_curve_too_short_to_draw_is_none():
    from bot.nemo import plot

    assert plot.render([], "1d") is None
    assert plot.render([(dt.datetime.now(dt.UTC), 3)], "1d") is None
    assert plot.render(activity.shaped(STATS)["curves"]["1d"], "2y") is None


def test_the_span_follows_the_age_of_the_post():
    from bot.nemo import plot

    assert plot.span_for(60) == "1h"
    assert plot.span_for(5 * 3600) == "1d"
    assert plot.span_for(3 * 86400) == "1w"
    assert plot.span_for(40 * 86400) == "30d"


class Uploader:
    def __init__(self, answer=None, blows_up=False):
        self.answer = answer if answer is not None else {"files": [{"id": "F1"}]}
        self.blows_up = blows_up
        self.sent = []

    def files_upload_v2(self, **asked):
        if self.blows_up:
            raise RuntimeError("not_allowed")
        self.sent.append(asked)
        return self.answer


def test_the_chart_goes_to_slack_privately_and_comes_back_as_a_file_id():
    said = activity.shaped(STATS)
    client = Uploader()
    posted = dt.datetime.now(dt.UTC) - dt.timedelta(hours=5)
    file_id, span = activity.chart(client, said["curves"], posted, said["viewers"])
    assert (file_id, span) == ("F1", "1d")
    assert client.sent[0]["filename"] == "activity-1d.png"
    assert "channel" not in client.sent[0], "the file is not shared anywhere"


def test_a_chart_slack_will_not_take_is_simply_left_out():
    said = activity.shaped(STATS)
    file_id, span = activity.chart(Uploader(blows_up=True), said["curves"],
                                   dt.datetime.now(dt.UTC), said["viewers"])
    assert file_id is None and span == "1h"


def test_the_card_carries_the_chart_and_the_way_to_the_page():
    said = activity.shaped(STATS)
    view = card.view(ROOM, TS, ME, "hi", said, chart=("F1", "1d"),
                     activity_url="https://nemo.test/messages/C0ANNOUNCE/1790701062.123456")
    image = next(one for one in view["blocks"] if one["type"] == "image")
    assert image["slack_file"] == {"id": "F1"}
    buttons = next(one for one in view["blocks"] if one["type"] == "actions")["elements"]
    assert buttons[0]["action_id"] == card.OPEN_ACTIVITY
    assert buttons[0]["url"].endswith(f"/messages/{ROOM}/{TS}")
