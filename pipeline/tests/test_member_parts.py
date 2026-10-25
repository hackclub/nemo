from types import SimpleNamespace

import pytest

from bot.core import formatting
from bot.nemo.views import report
from bot.relay import messages


def test_split_text_short_text_returns_single_part():
    assert formatting.split_text("hello there", limit=50) == ["hello there"]


def test_split_text_over_limit_splits_on_paragraph_then_line_then_word():
    paragraphs = "a" * 30 + "\n\n" + "b" * 30
    lines = "a" * 30 + "\n" + "b" * 30
    words = "a" * 30 + " " + "b" * 30

    assert formatting.split_text(paragraphs, limit=40) == ["a" * 30, "b" * 30]
    assert formatting.split_text(lines, limit=40) == ["a" * 30, "b" * 30]
    assert formatting.split_text(words, limit=40) == ["a" * 30, "b" * 30]


def test_split_text_without_spaces_cuts_at_limit():
    assert formatting.split_text("x" * 95, limit=40) == ["x" * 40, "x" * 40, "x" * 15]


def test_split_text_slack_link_is_not_split():
    link = "<https://example.com/x|the thread>"
    text = "w" * 30 + " " + link + " " + "z" * 30

    assert formatting.split_text(text, limit=60) == ["w" * 30, link, "z" * 30]


def test_member_parts_escapes_angle_brackets_and_ampersand_keeps_links():
    parts = formatting.member_parts("1 < 2 & <https://example.com|link>")

    assert parts == ["1 &lt; 2 &amp; <https://example.com|link>"]
    assert formatting.member_parts("   ") == []


def test_escape_keeps_slack_entities_single_escaped():
    assert formatting.escape("&gt; quoted &amp; &lt;b&gt;") == "&gt; quoted &amp; &lt;b&gt;"
    assert formatting.escape("a & b <!channel> &copy;") == "a &amp; b &lt;!channel&gt; &amp;copy;"


def test_follow_up_text_keeps_slack_quote_and_link():
    text = "&gt; <https://hackclub.slack.com/archives/C1/p1|alexren in #electronics> not allowed\nHello"

    assert report.escape_but_mentions(text) == text


class FakeSlack:
    def __init__(self, failing_at=None):
        self.failing_at = failing_at
        self.posted = []

    def chat_postMessage(self, **kwargs):
        if len(self.posted) == self.failing_at:
            raise RuntimeError("ratelimited")
        self.posted.append(kwargs)
        return {"ts": f"1.{len(self.posted)}"}


def queued_message(body):
    return SimpleNamespace(id=9, body=body, channel_id="D1", thread_ts="1.0", mode="body", requested_by=None)


@pytest.fixture
def long_body():
    return "\n\n".join(f"paragraph {index} " + "word " * 500 for index in range(3))


def test_post_message_long_body_posts_parts_in_order(long_body):
    relay = messages.MessageRelay()
    relay.client = FakeSlack()

    assert relay.post_message(queued_message(long_body)) == "1.1"
    texts = [one["text"] for one in relay.client.posted]
    assert len(texts) == 3
    assert [text.split(" ")[1] for text in texts] == ["0", "1", "2"]
    assert all(len(text) <= formatting.MEMBER_PART_LIMIT for text in texts)
    assert all(one["thread_ts"] == "1.0" for one in relay.client.posted)


def test_post_message_second_part_failure_returns_first_ts(long_body):
    relay = messages.MessageRelay()
    relay.client = FakeSlack(failing_at=1)

    assert relay.post_message(queued_message(long_body)) == "1.1"


def test_post_message_first_part_failure_raises_runtime_error(long_body):
    relay = messages.MessageRelay()
    relay.client = FakeSlack(failing_at=0)

    with pytest.raises(RuntimeError):
        relay.post_message(queued_message(long_body))


def test_member_parts_keeps_user_and_channel_mentions_escapes_broadcasts():
    parts = formatting.member_parts("thanks <@U123ABC> in <#C1|lounge> cc <!here> <!subteam^S1|@mods>")

    assert parts == ["thanks <@U123ABC> in <#C1|lounge> cc &lt;!here&gt; &lt;!subteam^S1|@mods&gt;"]
