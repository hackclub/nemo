import datetime as dt

from bot.nemo import mentions
from lib.proxy_client import InternalApiError

AT = dt.datetime(2026, 11, 17, 12, 0, tzinfo=dt.UTC)


def row(**over):
    built = {"channel_id": "C1FIRE", "ts": "1763380800.000100", "thread_root_ts": None,
             "posted_at": AT, "author_id": "UAUTH"}
    built.update(over)
    return built


def test_count_text_pluralizes():
    assert mentions.count_text(1) == "1 mention"
    assert mentions.count_text(2) == "2 mentions"


def test_count_text_caps_at_max_count():
    assert mentions.count_text(mentions.MAX_COUNT) == "100 mentions"
    assert mentions.count_text(mentions.FETCH) == "100+ mentions"


def test_line_links_channel_author_and_message():
    text = mentions.line(row())

    assert "<#C1FIRE>" in text
    assert "<@UAUTH>" in text
    assert "<https://hackclub.slack.com/archives/C1FIRE/p1763380800000100|Open>" in text
    assert "thread reply" not in text


def test_line_marks_thread_reply_and_links_with_root():
    text = mentions.line(row(thread_root_ts="1763380000.000200"))

    assert "thread reply" in text
    assert "?thread_ts=1763380000.000200&cid=C1FIRE" in text


def test_line_thread_root_message_is_not_a_reply():
    text = mentions.line(row(thread_root_ts="1763380800.000100"))

    assert "thread reply" not in text
    assert "thread_ts" not in text


def test_line_without_author_shows_unknown():
    assert "Unknown" in mentions.line(row(author_id=None))


def test_build_reply_empty_is_bare_title():
    reply = mentions.build_reply("UM", [])

    assert reply["text"] == "No mentions"
    assert len(reply["blocks"]) == 1


def test_build_reply_shows_first_ten_rows():
    rows = [row(ts=f"1763380800.{n:06d}") for n in range(15)]

    reply = mentions.build_reply("UM", rows)

    assert reply["text"] == "*<@UM>*  15 mentions"
    texts = [one["text"]["text"] for one in reply["blocks"] if one["type"] == "section"][1:]
    assert len(texts) == mentions.SHOWN
    assert all("|Open>" in one for one in texts)


def test_build_reply_adds_web_button(monkeypatch):
    monkeypatch.setenv("APP_HOST", "nemo.example.com")

    reply = mentions.build_reply("UM", [row()])

    button = reply["blocks"][-1]["elements"][0]
    assert button["text"]["text"] == "Show in Nemo"
    assert button["url"] == "https://nemo.example.com/fd/members/UM?tab=mentions"


def test_build_reply_without_app_host_has_no_button(monkeypatch):
    monkeypatch.delenv("APP_HOST", raising=False)

    reply = mentions.build_reply("UM", [row()])

    assert [one["type"] for one in reply["blocks"]] == ["section", "divider", "section"]


def test_build_reply_quotes_message_text():
    reply = mentions.build_reply("UM", [row(text="first line\nsecond   line")])

    assert reply["blocks"][2]["text"]["text"].endswith("\n> first line second line")


def test_build_reply_shortens_long_text():
    reply = mentions.build_reply("UM", [row(text="word " * 400)])

    quote = reply["blocks"][2]["text"]["text"].split("\n", 1)[1]
    assert len(quote) <= mentions.TEXT_LIMIT
    assert quote.endswith("...")


def test_build_reply_row_without_text_has_header_only():
    reply = mentions.build_reply("UM", [row(text=None)])

    assert "\n" not in reply["blocks"][2]["text"]["text"]


def test_with_text_fetches_only_shown_rows_and_keeps_count():
    rows = [row(ts=f"1763380800.{n:06d}") for n in range(15)]
    fetched = []

    def fetch(one):
        fetched.append(one["ts"])
        return "text " + one["ts"]

    result = mentions.with_text(rows, fetch)

    assert len(result) == 15
    assert len(fetched) == mentions.SHOWN
    assert result[0]["text"] == "text " + rows[0]["ts"]
    assert "text" not in result[mentions.SHOWN]


def test_message_text_reads_top_level_message_from_history(monkeypatch):
    calls = []

    def history(channel_id, **kwargs):
        calls.append((channel_id, kwargs))
        return {"messages": [{"ts": "1763380800.000100", "text": "hello"}]}

    monkeypatch.setattr(mentions.privileged, "history", history)

    assert mentions.message_text(row()) == "hello"
    assert calls == [("C1FIRE", {"limit": 1, "oldest": "1763380800.000100", "latest": "1763380800.000100"})]


def test_message_text_reads_reply_from_replies(monkeypatch):
    calls = []

    def replies(channel_id, ts, **kwargs):
        calls.append((channel_id, ts, kwargs))
        return {"messages": [{"ts": "1763380000.000200", "text": "root"},
                             {"ts": "1763380800.000100", "text": "reply"}]}

    monkeypatch.setattr(mentions.privileged, "replies", replies)

    assert mentions.message_text(row(thread_root_ts="1763380000.000200")) == "reply"
    assert calls[0][:2] == ("C1FIRE", "1763380000.000200")


def test_message_text_returns_none_when_fetch_fails(monkeypatch):
    def history(channel_id, **kwargs):
        raise InternalApiError("channel_not_found")

    monkeypatch.setattr(mentions.privileged, "history", history)

    assert mentions.message_text(row()) is None


def test_message_text_returns_none_when_message_missing(monkeypatch):
    monkeypatch.setattr(mentions.privileged, "history", lambda channel_id, **kwargs: {"messages": []})

    assert mentions.message_text(row()) is None
