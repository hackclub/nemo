import app


def test_message_stats_internal_credential_allowed_for_nemo_and_web():
    assert "insights.messageStats" in app.NEMO_METHODS["internal"]
    assert "insights.messageStats" in app.WEB_METHODS["internal"]


def test_message_stats_not_in_writes():
    assert "insights.messageStats" not in app.WRITES


def test_nemo_writes_only_on_admin_credential():
    assert app.NEMO_METHODS["admin"] & app.WRITES == app.WRITE_METHODS["admin"]
    assert "insights.messageStats" not in app.NEMO_METHODS["admin"]


def test_message_stats_not_allowed_for_pipeline_internal_methods():
    assert "insights.messageStats" not in app.ALLOWED_METHODS["internal"]


def test_conversations_history_allowed_for_web_admin_credential():
    assert "conversations.history" in app.WEB_METHODS["admin"]


def test_conversations_history_not_in_writes():
    assert "conversations.history" not in app.WRITES


def test_nemo_admin_reads_limited_to_purge_and_publicize_methods():
    reads = app.NEMO_METHODS["admin"] - app.WRITE_METHODS["admin"]

    assert reads == {"conversations.history", "conversations.replies", "search.messages",
                     "conversations.info", "admin.conversations.search",
                     "admin.roles.entity.listAssignments"}
    assert not reads & app.WRITES


def test_conversations_replies_allowed_for_web_admin_credential():
    assert "conversations.replies" in app.WEB_METHODS["admin"]


def test_search_messages_not_allowed_for_web_admin():
    assert "search.messages" not in app.WEB_METHODS["admin"]


def test_purge_read_methods_have_separate_nemo_budget_keys():
    import budget

    for method in app.PURGE_READ_METHODS["admin"]:
        assert budget.keys_for("nemo", "admin", method) == [("nemo", "admin", method)]


def test_web_admin_methods_exclude_writes():
    assert not app.WEB_METHODS["admin"] & app.WRITES


def test_files_read_allowed_for_web_only():
    assert "files.read" in app.WEB_FILE_METHODS
    assert "files.read" not in app.ALLOWED_FILE_METHODS


def test_files_read_not_in_writes():
    assert "files.read" not in app.WRITES


FILE_URL = "https://files.slack.com/files-pri/T1-F1/image.png"


def test_file_address_accepts_only_the_file_host_and_file_paths():
    import file_client

    assert file_client.file_address(FILE_URL)
    assert file_client.file_address("https://FILES.slack.com/files-tmb/T1-F1-abc/image_480.png")
    for url in ("https://evil.example/files-pri/T1-F1/a.png",
                "https://files.slack.com.evil.example/files-pri/T1-F1/a.png",
                "https://hackclub.slack.com/files-pri/T1-F1/a.png",
                "https://slack.com/files-pri/T1-F1/a.png",
                "https://files.slack-edge.com/files-pri/T1-F1/a.png",
                "https://files.slack.com/api/conversations.history",
                "https://files.slack.com/",
                "https://files.slack.com/files-pri/../api/auth.test",
                "https://files.slack.com/files-pri/%2e%2e/api/auth.test",
                "https://files.slack.com/files-pri/./T1-F1/a.png"):
        assert not file_client.file_address(url), url


def test_url_of_non_slack_or_insecure_url_raises_file_error():
    import pytest

    import file_client

    for payload in ({}, {"url": "https://evil.example/a.png"},
                    {"url": "http://files.slack.com/files-pri/T1-F1/a.png"},
                    {"url": "https://hackclub.slack.com/admin"},
                    {"url": "https://files.slack.com/api/auth.test"}):
        with pytest.raises(file_client.FileError):
            file_client.url_of(payload)


def test_url_of_userinfo_or_port_raises_file_error():
    import pytest

    import file_client

    for url in ("https://user:pass@files.slack.com/files-pri/T1-F1/a.png",
                "https://files.slack.com@evil.example/files-pri/T1-F1/a.png",
                "https://files.slack.com\\@evil.example/files-pri/T1-F1/a.png",
                "https://files.slack.com:8443/files-pri/T1-F1/a.png"):
        with pytest.raises(file_client.FileError):
            file_client.url_of({"url": url})


def redirect(target, origin=FILE_URL):
    import io
    import urllib.request

    import file_client

    original = urllib.request.Request(origin, headers={"Cookie": "d=secret"})
    return file_client.SlackOnlyRedirects().redirect_request(
        original, io.BytesIO(), 302, "Found", {}, target
    )


def test_redirect_off_slack_or_off_the_file_paths_raises_file_error():
    import pytest

    import file_client

    for target in ("https://evil.example/a.png", "http://files.slack.com/files-pri/T1-F1/a.png",
                   "https://files.slack.com.evil.example/a.png",
                   "https://hackclub.slack.com/admin",
                   "https://files.slack.com/api/auth.test"):
        with pytest.raises(file_client.FileError):
            redirect(target)


def test_redirect_to_a_file_path_keeps_the_cookie():
    followed = redirect("https://files.slack.com/files-pri/T1-F1/b.png")

    assert followed.get_header("Cookie") == "d=secret"


def test_redirect_to_a_cdn_host_drops_the_cookie():
    followed = redirect("https://files.slack-edge.com/b.png")

    assert followed.full_url == "https://files.slack-edge.com/b.png"
    assert followed.get_header("Cookie") is None


def test_redirect_limit_is_three():
    import file_client

    assert file_client.SlackOnlyRedirects.max_redirections == 3


def test_url_of_slack_url_returns_url_unchanged():
    import file_client

    assert file_client.url_of({"url": FILE_URL}) == FILE_URL
