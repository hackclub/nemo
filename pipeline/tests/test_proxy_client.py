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
