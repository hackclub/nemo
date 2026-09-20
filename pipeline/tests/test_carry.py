from bot.core.wording import said, to_member
from bot.nemo import carry, channel
from bot.nemo.cards import report

ROOM = "C1"
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


def blob(monkeypatch, kind):
    monkeypatch.setattr(carry.blobs, "body_of", lambda conn, sha: (b"bytes", kind))


def test_a_bodyless_report_says_nothing_in_its_place():
    assert said("") == ""
    assert to_member(None) == ""


def test_a_bodyless_report_has_no_empty_quote_to_reject():
    built = report.blocks({"case_id": 1, "body": "", "files": [], "shares": []})
    kinds = [block["type"] for block in built]
    assert "rich_text" not in kinds, "an empty quote is invalid blocks"
    assert kinds[0] == "header"


def test_a_picture_goes_up_wearing_the_reporters_face(monkeypatch):
    blob(monkeypatch, "image/png")
    conn = Conn([(7, "shot.png", "image/png", "abc", 100)])
    slack = Slack()

    ts = carry.share(slack, conn, 5, ROOM, THREAD, wearing={"username": "Anonymous"})

    assert ts == "9.9"
    assert slack.uploads[0].get("channel") is None, "a blocked file stays private"
    sent = slack.posted[0]
    assert sent["username"] == "Anonymous"
    assert sent["blocks"] == [{
        "type": "image",
        "slack_file": {"id": "F1"},
        "alt_text": "screenshot the reporter sent, shot.png",
    }]
    assert conn.written == [("F1", 5, 7)]


def test_words_and_picture_ride_the_same_message(monkeypatch):
    blob(monkeypatch, "image/png")
    conn = Conn([(7, "shot.png", "image/png", "abc", 100)])
    slack = Slack()

    carry.share(slack, conn, 5, ROOM, THREAD, wearing={"username": "Anonymous"}, words="look")

    assert len(slack.posted) == 1, "one message, not a caption and then a picture"
    kinds = [block["type"] for block in slack.posted[0]["blocks"]]
    assert kinds == ["section", "image"]


def test_a_file_slack_will_not_render_is_named_then_uploaded(monkeypatch):
    blob(monkeypatch, "application/pdf")
    conn = Conn([(7, "notes.pdf", "application/pdf", "abc", None)])
    slack = Slack()

    ts = carry.share(slack, conn, 5, ROOM, THREAD, wearing={"username": "Anonymous"})

    assert ts == "9.9", "the thread still needs a message to hang the case on"
    assert slack.posted[0]["username"] == "Anonymous"
    assert ":paperclip: notes.pdf" in slack.posted[0]["blocks"][0]["text"]["text"]
    assert slack.uploads[0]["channel"] == ROOM, "a file slack cannot block goes up on its own"


def test_nothing_to_carry_posts_nothing(monkeypatch):
    conn = Conn([])
    slack = Slack()

    assert carry.share(slack, conn, 5, ROOM, THREAD, wearing={"username": "Anonymous"}) is None
    assert slack.posted == []


def test_a_face_slack_cannot_reach_is_not_offered(monkeypatch):
    monkeypatch.delenv("ANONYMOUS_ICON_URL", raising=False)
    monkeypatch.setenv("APP_HOST", "localhost:3000")
    assert channel.anonymous_face() is None, "slack cannot fetch localhost"

    monkeypatch.setenv("APP_HOST", "fire.hackclub.com")
    assert channel.anonymous_face() == "https://fire.hackclub.com/anonymous.png"

    monkeypatch.setenv("ANONYMOUS_ICON_URL", "https://elsewhere.example/a.png")
    assert channel.anonymous_face() == "https://elsewhere.example/a.png"


def test_an_anonymous_reporter_is_worn_like_any_other_face(monkeypatch):
    monkeypatch.setenv("ANONYMOUS_ICON_URL", "https://fire.example/anonymous.png")
    worn = channel.as_reporter(None, True, None)
    assert worn["username"] == "Anonymous"
    assert worn["icon_url"] == "https://fire.example/anonymous.png"


def card_case():
    return {"case_id": 6, "is_anonymous": True, "reporter_user_id": None, "subjects": [],
            "other_cases": 0, "assignees": [], "category_key": None, "threads": 1,
            "body": "", "files": [], "shares": []}


def card(**over):
    case = {"case_id": 2, "body": "he keeps following me", "files": [], "shares": [],
            "is_anonymous": False, "reporter_user_id": "UALICE", "subjects": ["UBOB"],
            "other_cases": 2, "assignees": [], "category_key": "bullying"}
    case.update(over)
    return report.blocks(case)


def lines(built):
    return [
        " ".join(part["text"] for part in block["elements"])
        for block in built if block["type"] == "context"
    ]


def test_the_card_names_the_reporter_above_the_words():
    built = card()
    assert built[0]["type"] == "header"
    assert built[1]["type"] == "context", "who raised it sits under the header"

    top = lines(built)[0]
    assert "<@UALICE> reported it" in top
    assert "about <@UBOB>" in top
    assert "2 other case" in top


def test_the_footer_keeps_only_standing_and_the_link():
    top, *rest = lines(card())
    assert "Open" not in top
    assert any("Open" in one for one in rest)
    assert all("reported it" not in one for one in rest), "the reporter is named once"


def test_an_anonymous_card_says_so_where_the_name_would_be():
    top = lines(card(is_anonymous=True, reporter_user_id=None))[0]
    assert "reported anonymously" in top


def test_the_card_wears_the_reporters_face_but_keeps_its_metadata(monkeypatch):
    monkeypatch.setenv("ANONYMOUS_ICON_URL", "https://fire.example/anonymous.png")
    worn = channel.only_the_face(None, True, None)
    assert worn == {
        "username": "Anonymous",
        "icon_url": "https://fire.example/anonymous.png",
    }
    assert "metadata" not in worn, "the card's own metadata must survive"


LINK = "https://hackclub.slack.com/archives/C0BNYU3JK3Q/p1786970526885769"


def linked(**over):
    share = {"kind": "unfurl", "source_channel_id": "C0BNYU3JK3Q", "source_channel_name": None,
             "source_ts": "1786970526.885769", "is_reachable": True,
             "source_author_user_id": "U092KBRD5SB", "source_body": "mmm", "permalink": LINK}
    share.update(over)
    return share


def pointing(shares):
    return card(body=f"<{LINK}|{LINK}>", shares=shares, threads=1)


def quotes(built):
    return [b for b in built if b["type"] == "rich_text"]


def test_a_link_slack_never_resolved_is_still_quoted():
    built = pointing([linked(is_reachable=False, source_body=None, permalink=None)])

    said = quotes(built)
    assert len(said) == 1, "the link is all we have, so it stays"
    assert said[0]["elements"][0]["elements"][0]["type"] == "link"


def test_a_channel_with_no_name_is_left_for_slack_to_resolve():
    said = report.evidence([linked(is_reachable=False, source_body=None)])

    assert said == [f"<#C0BNYU3JK3Q> · <{LINK}|open it> (a link, not shared)"]
    assert "|<#" not in said[0], "a channel mention must not sit inside a link label"


def test_a_named_channel_still_reads_as_a_hash_link():
    assert report.evidence([linked(is_reachable=False, source_body=None,
                                   source_channel_name="lounge")]) == [f"<{LINK}|#lounge> (a link, not shared)"]


class Broken(Slack):
    def files_upload_v2(self, **kwargs):
        raise RuntimeError("slack said no")


def test_an_upload_that_failed_is_not_mistaken_for_nothing_to_carry(monkeypatch):
    blob(monkeypatch, "image/png")
    conn = Conn([(7, "shot.png", "image/png", "abc", 100)])

    try:
        carry.share(Broken(), conn, 5, ROOM, THREAD, wearing={"username": "Anonymous"})
    except RuntimeError as failure:
        assert "not settled" in str(failure)
    else:
        raise AssertionError("a failed upload must raise so the message is retried")

    assert conn.written == [], "nothing is marked mirrored when nothing went up"


def test_a_reply_that_is_only_words_lets_slack_unfurl_its_links(monkeypatch):
    conn = Conn([])
    slack = Slack()

    ts = carry.share(slack, conn, 5, ROOM, THREAD,
                     wearing={"username": "Anonymous"}, words=f"look at {LINK}")

    assert ts == "9.9"
    sent = slack.posted[0]
    assert "blocks" not in sent, "blocks suppress the unfurl slack would draw"
    assert sent["unfurl_links"] is True
    assert sent["username"] == "Anonymous"


def test_a_reply_with_a_picture_still_uses_blocks(monkeypatch):
    blob(monkeypatch, "image/png")
    conn = Conn([(7, "shot.png", "image/png", "abc", 100)])
    slack = Slack()

    carry.share(slack, conn, 5, ROOM, THREAD,
                wearing={"username": "Anonymous"}, words="look")

    assert [b["type"] for b in slack.posted[0]["blocks"]] == ["section", "image"]


def test_a_share_shown_in_full_is_not_listed_again_below():
    assert report.evidence([linked()]) == []


def test_nemo_cites_every_reachable_source_itself():
    for kind in ("unfurl", "forward", "link"):
        case = dict(card_case(), shares=[linked(kind=kind)])
        built = report.what_they_reported(case)
        assert built, f"nemo is not in the source channel, so slack draws nothing for {kind}"
        assert built[0]["elements"][0]["text"].startswith("<@U092KBRD5SB> in <#C0BNYU3JK3Q>")


def test_a_source_with_no_words_is_not_cited_as_an_empty_quote():
    case = dict(card_case(), shares=[linked(source_body="", is_reachable=False)])
    assert report.what_they_reported(case) == []
