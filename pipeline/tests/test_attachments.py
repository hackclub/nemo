from bot.core.formatting import member_parts, quote_text
from bot.nemo import attachments, channel
from bot.nemo.views import report

CHANNEL_ID = "C1"
THREAD = "100.000"


class Conn:
    def __init__(self, rows):
        self.rows = rows
        self.written = []

    def execute(self, sql, args=None):
        if "SELECT" in sql:
            return self
        self.written.append(args)
        return self

    def fetchall(self):
        return self.rows


class Slack:
    def __init__(self):
        self.uploads = []
        self.posted = []

    def files_upload_v2(self, **kwargs):
        self.uploads.append(kwargs)
        return {"files": [{"id": f"F{len(self.uploads)}"}]}

    def chat_postMessage(self, **kwargs):
        self.posted.append(kwargs)
        return {"ts": "9.9"}


def stub_file_body(monkeypatch, kind):
    monkeypatch.setattr(attachments.blobs, "body_of", lambda conn, sha: (b"bytes", kind))


def test_quote_text_and_member_parts_empty_body_return_empty():
    assert quote_text("") == ""
    assert member_parts(None) == []


def test_build_blocks_empty_body_omits_rich_text_quote():
    built = report.build_blocks({"case_id": 1, "body": "", "files": [], "shares": []})
    kinds = [block["type"] for block in built]
    assert "rich_text" not in kinds, "an empty quote is invalid blocks"
    assert kinds[0] == "card"












def test_share_without_files_or_body_returns_none_and_posts_nothing(monkeypatch):
    conn = Conn([])
    slack = Slack()

    assert attachments.share(slack, conn, 5, CHANNEL_ID, THREAD, author_fields={"username": "Anonymous"}) is None
    assert slack.posted == []


def test_anonymous_icon_url_returns_none_for_localhost_and_url_otherwise(monkeypatch):
    monkeypatch.delenv("ANONYMOUS_ICON_URL", raising=False)
    monkeypatch.setenv("APP_HOST", "localhost:3000")
    assert channel.anonymous_icon_url() is None, "slack cannot fetch localhost"

    monkeypatch.setenv("APP_HOST", "fire.hackclub.com")
    assert channel.anonymous_icon_url() == "https://fire.hackclub.com/anonymous.png"

    monkeypatch.setenv("ANONYMOUS_ICON_URL", "https://elsewhere.example/a.png")
    assert channel.anonymous_icon_url() == "https://elsewhere.example/a.png"


def test_reporter_author_fields_anonymous_returns_username_and_icon_url(monkeypatch):
    monkeypatch.setenv("ANONYMOUS_ICON_URL", "https://fire.example/anonymous.png")
    identity = channel.reporter_author_fields(None, True, None)
    assert identity["username"] == "Anonymous"
    assert identity["icon_url"] == "https://fire.example/anonymous.png"


CASE_URL = "https://fire.example/fd/cases/2"


def card(**over):
    case = {"case_id": 2, "body": "he keeps following me", "shares": [],
            "is_anonymous": False, "reporter_user_id": "UALICE", "subjects": ["UBOB"],
            "assignees": [], "category_key": "bullying"}
    case.update(over)
    return report.build_blocks(case)


def test_build_blocks_returns_single_plain_rich_text_section():
    built = card(url=CASE_URL)
    assert [block["type"] for block in built] == ["rich_text"]
    assert built[0]["elements"][0]["type"] == "rich_text_section", "plain text, not a quote"
    assert "Case 2" not in str(built), "the case number lives in the thread"


def test_build_blocks_excludes_reporter_subject_and_category_text():
    text = str(card(is_anonymous=False))
    for excluded in ("UALICE", "UBOB", "Bullying", "reported", "overflow"):
        assert excluded not in text


def test_header_blocks_render_case_card_titled_with_number_and_state():
    assert report.header_blocks({"case_id": 2})[0]["title"]["text"] == "Case 2, open"


def test_build_blocks_empty_body_returns_header_blocks():
    built = card(body="", blocks=None, url=CASE_URL)
    assert built == report.header_blocks(
        {"case_id": 2, "subjects": ["UBOB"], "assignees": [], "category_key": "bullying"})
    assert not report.needs_header({"case_id": 2, "body": "", "shares": []})


def test_build_blocks_simple_rich_text_keeps_bold_style():
    blocks = [{"type": "rich_text", "elements": [
        {"type": "rich_text_section", "elements": [
            {"type": "text", "text": "this is "},
            {"type": "text", "text": "urgent", "style": {"bold": True}},
        ]},
    ]}]
    built = card(blocks=blocks)
    quote = next(b for b in built if b["type"] == "rich_text")
    runs = quote["elements"][0]["elements"]
    assert {"type": "text", "text": "urgent", "style": {"bold": True}} in runs


def test_build_blocks_rich_text_list_keeps_bullets_in_quote():
    blocks = [{"type": "rich_text", "elements": [
        {"type": "rich_text_list", "style": "bullet", "elements": [
            {"type": "rich_text_section", "elements": [{"type": "text", "text": "one"}]},
        ]},
    ]}]
    built = card(blocks=blocks)
    quote = next(b for b in built if b["type"] == "rich_text")
    assert quote["elements"][0]["elements"] == [
        {"type": "text", "text": "• "}, {"type": "text", "text": "one"}, {"type": "text", "text": "\n"},
    ]


def test_build_blocks_unknown_rich_text_part_falls_back_to_unescaped_body():
    blocks = [{"type": "rich_text", "elements": [{"type": "rich_text_unknown", "elements": []}]}]
    built = card(blocks=blocks, body="&gt; quoted &amp; more")
    quote = next(b for b in built if b["type"] == "rich_text")
    assert quote["elements"][0]["elements"] == [{"type": "text", "text": "> quoted & more"}]


def test_build_blocks_without_blocks_quotes_plain_body():
    built = card(blocks=None)
    quote = next(b for b in built if b["type"] == "rich_text")
    assert quote["elements"][0]["elements"] == [
        {"type": "text", "text": "he keeps following me"}
    ]


def test_author_display_fields_anonymous_omits_metadata(monkeypatch):
    monkeypatch.setenv("ANONYMOUS_ICON_URL", "https://fire.example/anonymous.png")
    identity = channel.author_display_fields(None, True, None)
    assert identity == {
        "username": "Anonymous",
        "icon_url": "https://fire.example/anonymous.png",
    }
    assert "metadata" not in identity, "the card's own metadata must survive"


LINK = "https://hackclub.slack.com/archives/C0BNYU3JK3Q/p1786970526885769"


def link_share(**over):
    share = {"kind": "unfurl", "source_channel_id": "C0BNYU3JK3Q", "source_channel_name": None,
             "source_ts": "1786970526.885769", "is_reachable": True,
             "source_author_user_id": "U092KBRD5SB", "source_body": "mmm", "permalink": LINK}
    share.update(over)
    return share


def card_with_link(shares):
    return card(body=f"<{LINK}|{LINK}>", shares=shares)


def quotes(built):
    return [b for b in built if b["type"] == "rich_text"]


def test_build_blocks_unreachable_link_share_keeps_link_quote():
    built = card_with_link([link_share(is_reachable=False, source_body=None, permalink=None)])

    quote_blocks = quotes(built)
    assert len(quote_blocks) == 1, "the link is all we have, so it stays"
    assert quote_blocks[0]["elements"][0]["elements"][0]["type"] == "link"


class FailingUploadSlack(Slack):
    def files_upload_v2(self, **kwargs):
        raise RuntimeError("slack said no")




def test_share_body_only_posts_text_with_unfurl_links(monkeypatch):
    conn = Conn([])
    slack = Slack()

    ts = attachments.share(slack, conn, 5, CHANNEL_ID, THREAD,
                     author_fields={"username": "Anonymous"}, body=f"look at {LINK}")

    assert ts == "9.9"
    message = slack.posted[0]
    assert "blocks" not in message, "blocks suppress the unfurl slack would draw"
    assert message["unfurl_links"] is True
    assert message["username"] == "Anonymous"




def test_build_blocks_with_shares_omits_linked_message_body():
    built = card(shares=[link_share()])
    assert [b["type"] for b in built] == ["rich_text"]
    assert "mmm" not in str(built), "linked messages go in the thread, not on the card"


class FakeConn:
    def __init__(self, ts=None):
        self.ts = ts
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append(" ".join(sql.split())[:60])
        return self

    def fetchone(self):
        return (self.ts,)


def test_claim_card_sql_locks_row_and_reads_forwarded_ts():
    assert "FOR UPDATE" in channel.CLAIM_CARD, "two threads must not both post a card"
    assert "forwarded_ts" in channel.CLAIM_CARD


def test_share_image_without_body_uploads_into_thread_and_posts_no_message(monkeypatch):
    stub_file_body(monkeypatch, "image/png")
    conn = Conn([(7, "shot.png", "abc")])
    slack = Slack()

    ts = attachments.share(slack, conn, 5, CHANNEL_ID, THREAD, author_fields={"username": "Anonymous"})

    assert ts is None
    assert slack.posted == []
    assert slack.uploads[0]["channel"] == CHANNEL_ID
    assert slack.uploads[0]["thread_ts"] == THREAD
    assert slack.uploads[0]["filename"] == "shot.png"
    assert conn.written == [("F1", 5, 7)]


def test_share_body_and_image_posts_text_as_author_then_uploads_into_thread(monkeypatch):
    stub_file_body(monkeypatch, "image/png")
    conn = Conn([(7, "shot.png", "abc")])
    slack = Slack()

    ts = attachments.share(slack, conn, 5, CHANNEL_ID, THREAD, author_fields={"username": "Anonymous"},
                           body="look")

    assert ts == "9.9"
    assert slack.posted == [{"channel": CHANNEL_ID, "thread_ts": THREAD, "text": "look",
                             "unfurl_links": True, "unfurl_media": True, "username": "Anonymous"}]
    assert slack.uploads[0]["thread_ts"] == THREAD
    assert conn.written == [("F1", 5, 7)]


def test_share_summary_without_body_posts_file_name_as_author(monkeypatch):
    stub_file_body(monkeypatch, "application/pdf")
    conn = Conn([(7, "notes.pdf", "abc")])
    slack = Slack()

    ts = attachments.share(slack, conn, 5, CHANNEL_ID, THREAD, author_fields={"username": "Anonymous"},
                           summary=True)

    assert ts == "9.9"
    assert slack.posted[0]["text"] == "notes.pdf"
    assert slack.posted[0]["username"] == "Anonymous"
    assert slack.uploads[0]["channel"] == CHANNEL_ID


def test_share_upload_failure_writes_no_rows(monkeypatch):
    stub_file_body(monkeypatch, "image/png")
    conn = Conn([(7, "shot.png", "abc")])

    ts = attachments.share(FailingUploadSlack(), conn, 5, CHANNEL_ID, THREAD,
                           author_fields={"username": "Anonymous"})

    assert ts is None
    assert conn.written == []
