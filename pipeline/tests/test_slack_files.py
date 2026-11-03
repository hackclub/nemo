import contextlib
import io
import urllib.error
import urllib.request
import zlib

import pytest

from bot.core import blobs, slack_files
from bot.nemo import attachments
from bot.relay import file_notices, intake_files, reply

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 24
TOKEN = "xoxb-secret"


@pytest.mark.parametrize(("head", "mimetype"), [
    (PNG, "image/png"),
    (b"\xff\xd8\xff\xe0" + b"\x00" * 20, "image/jpeg"),
    (b"GIF89a" + b"\x00" * 20, "image/gif"),
    (b"RIFF\x00\x00\x00\x00WEBPVP8 ", "image/webp"),
    (b"\x00\x00\x00\x18ftypheic" + b"\x00" * 8, "image/heic"),
    (b"\x00\x00\x00\x14ftypqt  " + b"\x00" * 8, "video/quicktime"),
    (b"\x00\x00\x00\x20ftypisom" + b"\x00" * 8, "video/mp4"),
    (b"\x1a\x45\xdf\xa3" + b"\x00" * 20, "video/webm"),
    (b"<svg xmlns='http://www.w3.org/2000/svg'><script/></svg>", None),
    (b"<!doctype html><script>alert(1)</script>", None),
    (b"%PDF-1.7\n", "application/pdf"),
    (b" %PDF-1.7\n", None),
    (b"MZ\x90\x00", None),
    (b"\x00\x00\x00\x20ftypavif" + b"\x00" * 8, None),
    (b"", None),
])
def test_media_type_header_bytes_return_detected_mimetype(head, mimetype):
    assert blobs.media_type(head) == mimetype


@pytest.mark.parametrize(("declared", "allowed"), [
    ("image/png", True), ("IMAGE/JPEG; charset=binary", True), ("video/mp4", True),
    ("image/svg+xml", False), ("text/html", False), ("application/pdf", True), ("application/zip", False), (None, False),
])
def test_is_media_type_declared_type_allows_images_videos_and_pdf_only(declared, allowed):
    assert blobs.is_media_type(declared) is allowed


def redirect(from_url, to_url):
    handler = slack_files.SlackOnlyRedirect()
    request = urllib.request.Request(from_url, headers={"Authorization": f"Bearer {TOKEN}"})
    return handler.redirect_request(request, io.BytesIO(), 302, "Found", {}, to_url)


def test_redirect_outside_slack_raises_http_error():
    with pytest.raises(urllib.error.HTTPError, match="outside Slack"):
        redirect("https://files.slack.com/files-pri/T1-F1/a.png", "https://evil.example/steal")


def test_redirect_to_http_raises_http_error():
    with pytest.raises(urllib.error.HTTPError):
        redirect("https://files.slack.com/files-pri/T1-F1/a.png", "http://files.slack.com/a.png")


def test_redirect_to_other_slack_host_drops_authorization():
    redirected = redirect("https://files.slack.com/files-pri/T1-F1/a.png", "https://files.slack-edge.com/a.png")

    assert redirected.get_header("Authorization") is None


def test_redirect_same_host_preserves_authorization():
    redirected = redirect("https://files.slack.com/files-pri/T1-F1/a.png", "https://files.slack.com/files-pri/T1-F1/b.png")

    assert redirected.get_header("Authorization") == f"Bearer {TOKEN}"


def test_slack_only_redirect_max_redirections_is_three():
    assert slack_files.SlackOnlyRedirect.max_redirections == 3


@pytest.mark.parametrize("url", ["https://evil.example/a.png", "http://files.slack.com/a.png",
                                 "https://files.slack.com.evil.example/a.png", "file:///etc/passwd", None])
def test_download_non_slack_url_returns_refused_without_request(monkeypatch, url):
    monkeypatch.setattr(slack_files.OPENER, "open", lambda *args, **kwargs: pytest.fail("no request expected"))

    assert slack_files.download(url, TOKEN, 100) == (None, "refused", blobs.NOT_SLACK_URL)


class FakeResponse:
    def __init__(self, body, content_type="image/png", length=None, status=200):
        self.body = body
        self.status = status
        self.headers = {"Content-Type": content_type, "Content-Length": length}

    def read(self, size):
        return self.body[:size]

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


@pytest.mark.parametrize(("response", "state"), [
    (FakeResponse(PNG), "stored"),
    (FakeResponse(b"x" * 200), "too_large"),
    (FakeResponse(PNG, length="999"), "too_large"),
    (FakeResponse(b"<html>login</html>", content_type="text/html"), "refused"),
])
def test_download_slack_response_returns_state_by_size_and_type(monkeypatch, response, state):
    monkeypatch.setattr(slack_files.OPENER, "open", lambda request, timeout: response)

    assert slack_files.download("https://files.slack.com/files-pri/T1-F1/a.png", TOKEN, 100)[1] == state


def test_attachments_fetch_refused_download_returns_none(monkeypatch):
    monkeypatch.setattr(attachments.slack_files, "download", lambda url, token, limit: (None, "refused", "html"))

    assert attachments.fetch("https://files.slack.com/a.png", TOKEN, 100) is None


@pytest.fixture
def drain_calls(monkeypatch):
    calls = {"rows": [], "stored": [], "failed": [], "downloads": []}

    @contextlib.contextmanager
    def fake_session():
        yield None

    monkeypatch.setattr(intake_files, "session", fake_session)
    monkeypatch.setattr(intake_files.blobs, "waiting", lambda conn, limit: calls["rows"])
    monkeypatch.setattr(intake_files.blobs, "store_blob",
                        lambda conn, file_id, body, mimetype: calls["stored"].append((file_id, mimetype)))
    monkeypatch.setattr(intake_files.blobs, "mark_failed",
                        lambda conn, file_id, state, error: calls["failed"].append((file_id, state, error)))
    return calls


def test_drain_declared_non_media_marks_refused_without_download(drain_calls, monkeypatch):
    drain_calls["rows"].append((1, "F1", "https://files.slack.com/a.zip", 10, "application/zip", False))
    monkeypatch.setattr(intake_files, "download", lambda *args: pytest.fail("no download expected"))

    assert intake_files.drain(TOKEN) == 0
    assert drain_calls["failed"] == [(1, "refused", blobs.NOT_MEDIA)]


def test_drain_chat_files_reads_only_chat_files_with_the_given_token(drain_calls, monkeypatch):
    monkeypatch.setattr(intake_files.blobs, "waiting", lambda conn, limit: pytest.fail("intake files read"))
    monkeypatch.setattr(intake_files.blobs, "waiting_chat_files", lambda conn, limit: [
        (3, "F3", "https://files.slack.com/c.png", 10, "image/png", False),
    ])
    tokens = []
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 24
    monkeypatch.setattr(intake_files, "download",
                        lambda url, token, limit: tokens.append(token) or (png, "stored", None))

    assert intake_files.drain_chat_files("xoxb-nemo") == 1
    assert tokens == ["xoxb-nemo"]
    assert drain_calls["stored"] == [(3, "image/png")]


PDF = b"%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n"


def pdf_with(extra):
    return PDF.replace(b"<< /Type /Catalog >>", b"<< /Type /Catalog " + extra + b" >>")


def object_stream(content):
    return (b"%PDF-1.7\n5 0 obj\n<< /Type /ObjStm /N 1 /First 4 /Filter /FlateDecode >>\nstream\n"
            + zlib.compress(content) + b"\nendstream\nendobj\n")


@pytest.mark.parametrize("body", [
    PDF,
    pdf_with(b"/URI (https://example.com)"),
    object_stream(b"1 0 << /Type /Catalog >>"),
])
def test_pdf_refusal_plain_pdf_is_accepted(body):
    assert blobs.pdf_refusal(body) is None


@pytest.mark.parametrize("body", [
    pdf_with(b"/OpenAction << /S /JavaScript /JS (app.alert(1)) >>"),
    pdf_with(b"/AA << /O 2 0 R >>"),
    pdf_with(b"/Names << /EmbeddedFiles 3 0 R >> /EmbeddedFile 3 0 R"),
    pdf_with(b"/Launch"),
    pdf_with(b"/Java#53cript"),
    pdf_with(b"/#4aS (x)"),
    object_stream(b"1 0 << /OpenAction << /S /JavaScript >> >>"),
])
def test_pdf_refusal_active_content_is_refused_even_when_escaped_or_compressed(body):
    assert blobs.pdf_refusal(body) == blobs.PDF_ACTIVE_CONTENT


def test_pdf_refusal_encrypted_pdf_is_refused():
    assert blobs.pdf_refusal(pdf_with(b"/Encrypt 9 0 R")) == blobs.PDF_ENCRYPTED


def test_pdf_refusal_corrupt_object_stream_is_ignored():
    body = b"%PDF-1.7\n<< /Type /ObjStm >>\nstream\nnot zlib\nendstream\n"
    assert blobs.pdf_refusal(body) is None


def test_drain_stores_clean_pdf_and_refuses_active_one(drain_calls, monkeypatch):
    drain_calls["rows"] += [(1, "F1", "https://files.slack.com/a.pdf", 10, "application/pdf", False),
                            (2, "F2", "https://files.slack.com/b.pdf", 10, "application/pdf", True)]
    bodies = {"https://files.slack.com/a.pdf": PDF,
              "https://files.slack.com/b.pdf": pdf_with(b"/JavaScript")}
    monkeypatch.setattr(intake_files, "download", lambda url, token, limit: (bodies[url], "stored", None))

    assert intake_files.drain(TOKEN) == 1
    assert drain_calls["stored"] == [(1, "application/pdf")]
    assert drain_calls["failed"] == [(2, "refused", blobs.PDF_ACTIVE_CONTENT)]


def test_drain_stores_mimetype_detected_from_bytes(drain_calls, monkeypatch):
    drain_calls["rows"] += [(1, "F1", "https://files.slack.com/a.jpg", 10, "image/jpeg", False),
                            (2, "F2", "https://files.slack.com/b.png", 10, "image/png", True)]
    bodies = {"https://files.slack.com/a.jpg": PNG, "https://files.slack.com/b.png": b"<html></html>"}
    monkeypatch.setattr(intake_files, "download", lambda url, token, limit: (bodies[url], "stored", None))

    assert intake_files.drain(TOKEN) == 1
    assert drain_calls["stored"] == [(1, "image/png")]
    assert drain_calls["failed"] == [(2, "refused", blobs.NOT_MEDIA)]


def test_drain_downloads_a_forwarded_file_with_nemos_token(drain_calls, monkeypatch):
    drain_calls["rows"] += [(1, "F1", "https://files.slack.com/a.png", 10, "image/png", True),
                            (2, "F2", "https://files.slack.com/b.png", 10, "image/png", False)]
    used = {}
    monkeypatch.setenv("NEMO_BOT_TOKEN", "xoxb-nemo")
    monkeypatch.setattr(
        intake_files, "download",
        lambda url, token, limit: used.update({url: token}) or (PNG, "stored", None),
    )

    intake_files.drain(TOKEN)

    assert used == {"https://files.slack.com/a.png": "xoxb-nemo",
                    "https://files.slack.com/b.png": TOKEN}


def test_drain_downloads_a_forwarded_file_with_the_relay_token_without_nemos(monkeypatch):
    monkeypatch.delenv("NEMO_BOT_TOKEN", raising=False)

    assert intake_files.drain_token(True, "xoxb-relay", None) == "xoxb-relay"
    assert intake_files.drain_token(False, "xoxb-relay", None) == "xoxb-relay"
    assert intake_files.drain_token(True, "xoxb-relay", "xoxb-nemo") == "xoxb-nemo"
    assert intake_files.drain_token(False, "xoxb-relay", "xoxb-nemo") == "xoxb-relay"


@pytest.mark.parametrize(("state", "error", "text"), [
    ("too_large", None, "Not sent: a&amp;b.mp4 (over 25 MiB). Send a smaller file or a link."),
    ("refused", blobs.NOT_MEDIA, "Not sent: a&amp;b.mp4 (only images, videos and PDFs are accepted)."),
    ("refused", blobs.PDF_ACTIVE_CONTENT, "Not sent: a&amp;b.mp4 (contains active content)."),
    ("refused", blobs.PDF_ENCRYPTED, "Not sent: a&amp;b.mp4 (encrypted)."),
    ("skipped", None, "Not sent: a&amp;b.mp4 (only files uploaded to Slack are accepted)."),
    ("refused", blobs.HTML_BODY, "Not sent: a&amp;b.mp4 (could not be downloaded). Send it again or send a link."),
    ("failed", "timeout", "Not sent: a&amp;b.mp4 (could not be downloaded). Send it again or send a link."),
])
def test_notice_text_state_and_error_return_message(state, error, text):
    assert file_notices.notice_text(state, error, "a&b.mp4") == text


def test_file_label_none_returns_file():
    assert reply.file_label(None) == "file"


class NoticeConn:
    def __init__(self, rows, claimed):
        self.rows = rows
        self.claimed = claimed
        self.released = []
        self.sql = None

    def execute(self, sql, args=None):
        self.sql, self.args = sql, args
        if sql == file_notices.RELEASE:
            self.released.append(args[0])
        return self

    def fetchall(self):
        return self.rows

    def fetchone(self):
        return (self.args[0],) if self.args[0] in self.claimed else None


class NoticeSlack:
    def __init__(self, failing=False):
        self.failing = failing
        self.posted = []

    def chat_postMessage(self, **kwargs):
        if self.failing:
            raise RuntimeError("ratelimited")
        self.posted.append(kwargs)
        return {"ts": "9.9"}


def notice_setup(monkeypatch, claimed):
    rows = [(1, "D1", "1.0", "too_large", None, "big.mp4"), (2, "D1", "1.0", "refused", blobs.NOT_MEDIA, "a.pdf")]
    conn = NoticeConn(rows, claimed)
    recorded = []

    @contextlib.contextmanager
    def fake_session():
        yield conn

    monkeypatch.setattr(file_notices, "session", fake_session)
    monkeypatch.setattr(file_notices.intake, "record",
                        lambda conn, event, direction: recorded.append((event["subtype"], direction)))
    return conn, recorded


def test_post_notices_claimed_file_posts_one_notice_and_records_outbound(monkeypatch):
    conn, recorded = notice_setup(monkeypatch, claimed={1})
    client = NoticeSlack()

    assert file_notices.post_notices(client) == 1
    assert [(one["channel"], one["thread_ts"]) for one in client.posted] == [("D1", "1.0")]
    assert recorded == [(file_notices.SUBTYPE, "outbound")]


def test_post_notices_slack_failure_releases_claims(monkeypatch):
    conn, recorded = notice_setup(monkeypatch, claimed={1, 2})

    assert file_notices.post_notices(NoticeSlack(failing=True)) == 0
    assert conn.released == [1, 2]
    assert recorded == []


def test_unnotified_files_filters_open_conversations_and_unnotified_inbound():
    sql = file_notices.UNNOTIFIED_FILES
    assert "c.handed_off_at IS NOT NULL AND c.closed_at IS NULL" in sql
    assert "f.reporter_notified_at IS NULL" in sql
    assert "m.direction = 'inbound'" in sql
    assert "NOT mf.forwarded" in sql


@pytest.mark.parametrize(("url", "allowed"), [
    ("https://files.slack.com/files-pri/T1-F1/a.png", True),
    ("https://FILES.slack.com/files-tmb/T1-F1-abc/a_480.png", True),
    ("https://files.slack.com/api/auth.test", False),
    ("https://files.slack.com/", False),
    ("https://hackclub.slack.com/files-pri/T1-F1/a.png", False),
    ("https://files.slack-edge.com/files-pri/T1-F1/a.png", False),
    ("https://files.slack.com/files-pri/../api/auth.test", False),
    ("https://files.slack.com/files-pri/%2e%2e/api/auth.test", False),
    ("https://user:pass@files.slack.com/files-pri/T1-F1/a.png", False),
    ("https://files.slack.com:8443/files-pri/T1-F1/a.png", False),
    ("https://files.slack.com:badport/files-pri/T1-F1/a.png", False),
    ("http://files.slack.com/files-pri/T1-F1/a.png", False),
    (None, False),
])
def test_file_url_accepts_only_the_file_host_and_file_paths(url, allowed):
    assert blobs.file_url(url) is allowed


def test_download_of_another_slack_host_is_refused_without_a_request(monkeypatch):
    monkeypatch.setattr(slack_files.OPENER, "open", lambda *args, **kwargs: pytest.fail("no request expected"))

    assert slack_files.download("https://hackclub.slack.com/admin", TOKEN, 100) == (
        None, "refused", blobs.NOT_SLACK_URL)


def test_redirect_to_a_non_file_path_on_the_same_host_drops_authorization():
    redirected = redirect("https://files.slack.com/files-pri/T1-F1/a.png", "https://files.slack.com/api/auth.test")

    assert redirected.get_header("Authorization") is None
