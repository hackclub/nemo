import pytest

from bot.engine import files


@pytest.fixture(autouse=True)
def no_cap_override(monkeypatch):
    monkeypatch.delenv("INTAKE_FILE_MAX_BYTES", raising=False)


def test_a_normal_image_is_kept():
    assert files.verdict(200, "image/png", 40311, 1000000) == ("stored", None)


def test_a_forbidden_file_is_refused_with_a_reason():
    state, error = files.verdict(403, None, 0, 1000)
    assert state == "refused"
    assert "403" in error


def test_an_unauthorised_file_is_refused():
    assert files.verdict(401, None, 0, 1000)[0] == "refused"


def test_a_missing_file_is_gone_and_needs_no_reason():
    assert files.verdict(404, None, 0, 1000) == ("gone", None)
    assert files.verdict(410, None, 0, 1000) == ("gone", None)


def test_any_other_status_is_a_failure_we_can_retry():
    state, error = files.verdict(500, None, 10, 1000)
    assert state == "failed"
    assert "500" in error


def test_a_login_page_is_not_a_file():
    state, error = files.verdict(200, "text/html; charset=utf-8", 5000, 1000000)
    assert state == "refused"
    assert "web page" in error


def test_the_content_type_check_ignores_case_and_parameters():
    assert files.verdict(200, "TEXT/HTML;charset=utf-8", 500, 10000)[0] == "refused"


def test_a_file_over_the_cap_is_not_kept():
    state, error = files.verdict(200, "image/png", 2000, 1000)
    assert state == "too_large"
    assert "1000" in error


def test_a_file_exactly_at_the_cap_is_kept():
    assert files.verdict(200, "image/png", 1000, 1000)[0] == "stored"


def test_an_empty_body_is_a_failure():
    state, error = files.verdict(200, "image/png", 0, 1000)
    assert state == "failed"
    assert "empty" in error


def test_the_cap_defaults_when_nothing_is_set():
    assert files.cap() == files.DEFAULT_CAP


def test_the_cap_can_be_raised(monkeypatch):
    monkeypatch.setenv("INTAKE_FILE_MAX_BYTES", "5")
    assert files.cap() == 5


def test_a_nonsense_cap_falls_back_to_the_default(monkeypatch):
    monkeypatch.setenv("INTAKE_FILE_MAX_BYTES", "not a number")
    assert files.cap() == files.DEFAULT_CAP


def test_a_zero_cap_falls_back_rather_than_refusing_everything(monkeypatch):
    monkeypatch.setenv("INTAKE_FILE_MAX_BYTES", "0")
    assert files.cap() == files.DEFAULT_CAP


def test_we_do_not_even_ask_for_something_slack_says_is_huge():
    assert files.too_big_to_ask(999, 1000) is False
    assert files.too_big_to_ask(1001, 1000) is True


def test_an_unknown_size_is_worth_asking_for():
    assert files.too_big_to_ask(None, 1000) is False
    assert files.too_big_to_ask(0, 1000) is False
