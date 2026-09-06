from lib.proxy_client import ProxyClient, plaintext_refused


def test_https_anywhere_is_fine():
    assert plaintext_refused("https://proxy.example.com", allow_plaintext="") is None


def test_plaintext_to_loopback_is_fine():
    assert plaintext_refused("http://127.0.0.1:8002", allow_plaintext="") is None
    assert plaintext_refused("http://localhost:8002", allow_plaintext="") is None
    assert plaintext_refused("http://host.docker.internal:8002", allow_plaintext="") is None


def test_plaintext_to_another_machine_is_refused():
    assert plaintext_refused("http://proxy.example.com:8002", allow_plaintext="") is not None


def test_plaintext_can_be_allowed_on_purpose():
    assert plaintext_refused("http://proxy.example.com", allow_plaintext="true") is None
    assert plaintext_refused("http://proxy.example.com", allow_plaintext="no") is not None


class Walker(ProxyClient):
    def __init__(self, pages):
        self.pages = pages
        self.asked = []

    def call(self, method, params, **kwargs):
        self.asked.append(params.get("cursor_mark"))
        return self.pages[len(self.asked) - 1]


def page(items, cursor):
    return {"rows": items, "next_cursor_mark": cursor}


def test_a_walk_stops_at_an_empty_page_by_default():
    client = Walker([page([{"n": 1}], "c1"), page([], "c2"), page([{"n": 2}], None)])

    walked = list(client.paginate("m", {}, "rows", cursor_param="cursor_mark"))

    assert walked == [{"n": 1}]
    assert len(client.asked) == 2


def test_a_walk_can_be_told_to_read_past_an_empty_page():
    client = Walker([page([{"n": 1}], "c1"), page([], "c2"), page([{"n": 2}], None)])

    walked = list(client.paginate(
        "m", {}, "rows", cursor_param="cursor_mark", allow_empty_pages=True))

    assert walked == [{"n": 1}, {"n": 2}]
    assert len(client.asked) == 3


def test_reading_past_empty_pages_still_ends_when_the_cursor_runs_out():
    client = Walker([page([], "c1"), page([], "c2"), page([], None)])

    walked = list(client.paginate(
        "m", {}, "rows", cursor_param="cursor_mark", allow_empty_pages=True))

    assert walked == []
    assert len(client.asked) == 3


def test_a_proxy_error_carries_its_status_and_whether_the_proxy_answered():
    import io
    import urllib.error
    from email.message import Message
    from lib.proxy_client import ProxyClient, ProxyError
    headers = Message()
    headers["X-Fault-Origin"] = "proxy"
    exc = urllib.error.HTTPError("http://x/call", 503, "Service Unavailable", headers, io.BytesIO(b'{"detail":"budget: spent"}'))
    try:
        ProxyClient(url="http://localhost:1", token="t")._raise_for_status(exc)
    except ProxyError as caught:
        assert caught.http_status == 503
        assert caught.had_fault_body is True
        assert "budget: spent" in str(caught)
    else:
        raise AssertionError("expected ProxyError")


def test_an_edge_answer_with_no_proxy_header_is_marked_as_such():
    import io
    import urllib.error
    from email.message import Message
    from lib.proxy_client import ProxyClient, ProxyError
    exc = urllib.error.HTTPError("http://x/call", 504, "Gateway Timeout", Message(), io.BytesIO(b"<html>"))
    try:
        ProxyClient(url="http://localhost:1", token="t")._raise_for_status(exc)
    except ProxyError as caught:
        assert caught.http_status == 504
        assert caught.had_fault_body is False


def test_retry_after_prefers_the_header_and_falls_back_cleanly():
    from email.message import Message
    from lib.proxy_client import retry_after

    class Exc:
        headers = Message()
    Exc.headers["Retry-After"] = "7"
    assert retry_after(Exc(), 2) == 7.0

    class Bad:
        headers = Message()
    Bad.headers["Retry-After"] = "soon"
    assert retry_after(Bad(), 3) == 3.0
    assert retry_after(type("E", (), {"headers": Message()})(), 4) == 4.0


def test_a_proxy_that_could_not_reach_slack_is_a_transport_fault_not_an_api_error():
    import io
    import urllib.error
    from email.message import Message
    from lib.proxy_client import ProxyClient, ProxyUnavailableError
    headers = Message()
    headers["X-Fault-Origin"] = "proxy"
    body = io.BytesIO(b'{"detail":"upstream unreachable: URLError: <urlopen error [Errno -3] Temporary failure in name resolution>"}')
    exc = urllib.error.HTTPError("http://localhost:1/call", 502, "Bad Gateway", headers, body)
    try:
        ProxyClient(url="http://localhost:1", token="t")._raise_for_status(exc)
    except ProxyUnavailableError as caught:
        assert caught.http_status == 502 and caught.had_fault_body is True
        assert "name resolution" in str(caught)
    else:
        raise AssertionError("expected ProxyUnavailableError")
