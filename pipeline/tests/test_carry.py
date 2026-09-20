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
