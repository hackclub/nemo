import app


def test_the_bot_reads_message_activity_on_the_internal_credential():
    assert "insights.messageStats" in app.NEMO_METHODS["internal"]
    assert "insights.messageStats" in app.WEB_METHODS["internal"]


def test_message_activity_is_never_logged_as_a_write():
    assert "insights.messageStats" not in app.WRITES


def test_the_bot_still_writes_only_on_the_admin_credential():
    assert app.NEMO_METHODS["admin"] == app.WRITE_METHODS["admin"]
    assert "insights.messageStats" not in app.NEMO_METHODS["admin"]


def test_the_pipeline_does_not_get_the_new_method_for_free():
    assert "insights.messageStats" not in app.ALLOWED_METHODS["internal"]


def test_the_web_reads_one_message_on_the_admin_credential():
    assert "conversations.history" in app.WEB_METHODS["admin"]


def test_reading_a_message_is_never_logged_as_a_write():
    assert "conversations.history" not in app.WRITES


def test_the_bot_does_not_get_to_read_history_for_free():
    assert "conversations.history" not in app.NEMO_METHODS.get("admin", frozenset())


def test_the_web_still_holds_no_writes():
    assert not app.WEB_METHODS["admin"] & app.WRITES


def test_the_web_may_read_a_file_and_nobody_else():
    assert "files.read" in app.WEB_FILE_METHODS
    assert "files.read" not in app.ALLOWED_FILE_METHODS


def test_reading_a_file_is_never_logged_as_a_write():
    assert "files.read" not in app.WRITES


def test_a_file_url_must_be_slack_hosted():
    import file_client

    assert file_client.hosted_by_slack("https://files.slack.com/files-pri/T1-F1/a.png")
    assert not file_client.hosted_by_slack("https://evil.example/a.png")
    assert not file_client.hosted_by_slack("https://files.slack.com.evil.example/a.png")


def test_a_file_url_elsewhere_is_refused():
    import pytest

    import file_client

    for said in ({}, {"url": "https://evil.example/a.png"},
                 {"url": "http://files.slack.com/a.png"}):
        with pytest.raises(file_client.FileError):
            file_client.url_of(said)


def test_a_slack_file_url_is_taken_as_it_stands():
    import file_client

    url = "https://files.slack.com/files-pri/T1-F1/image.png"
    assert file_client.url_of({"url": url}) == url
