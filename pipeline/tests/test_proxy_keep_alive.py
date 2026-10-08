import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from lib import proxy_client
from lib.proxy_client import ProxyClient, ProxyError


class Proxy:
    def __init__(self, status=200, close_after_first=False):
        self.status = status
        self.close_after_first = close_after_first
        self.connections = set()
        self.calls = 0
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            disable_nagle_algorithm = True

            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                owner.connections.add(self.client_address[1])
                owner.calls += 1
                body = json.dumps({"ok": owner.status < 400, "detail": "budget: spent"}).encode()
                self.send_response(owner.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                if owner.status == 429:
                    self.send_header("Retry-After", "1")
                self.end_headers()
                self.wfile.write(body)
                if owner.close_after_first and owner.calls == 1:
                    self.close_connection = True

            def log_message(self, *args):
                return None

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def client(self, keep_alive=True):
        return ProxyClient(url=self.url, token="t", keep_alive=keep_alive)

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def proxy():
    made = []

    def start(**kwargs):
        one = Proxy(**kwargs)
        made.append(one)
        return one

    yield start
    proxy_client._kept.pool = {}
    for one in made:
        one.stop()


def test_calls_on_one_thread_share_one_connection(proxy):
    server = proxy()
    client = server.client()

    for _ in range(3):
        assert client.call("chat.delete", {"ts": "1.1"}, max_retries=0) == {
            "ok": True, "detail": "budget: spent"}

    assert server.calls == 3
    assert len(server.connections) == 1


def test_a_new_client_on_the_same_thread_reuses_the_connection(proxy):
    server = proxy()

    server.client().call("chat.delete", max_retries=0)
    server.client().call("chat.delete", max_retries=0)

    assert len(server.connections) == 1


def test_without_keep_alive_every_call_opens_a_connection(proxy):
    server = proxy()
    client = server.client(keep_alive=False)

    client.call("chat.delete", max_retries=0)
    client.call("chat.delete", max_retries=0)

    assert len(server.connections) == 2


def test_a_connection_idle_too_long_is_replaced(proxy, monkeypatch):
    server = proxy()
    client = server.client()
    monkeypatch.setattr(proxy_client, "KEEP_IDLE_SECONDS", -1)

    client.call("chat.delete", max_retries=0)
    client.call("chat.delete", max_retries=0)

    assert len(server.connections) == 2


def test_a_connection_the_proxy_closed_is_retried_once_on_a_fresh_one(proxy):
    server = proxy(close_after_first=True)
    client = server.client()

    client.call("chat.delete", max_retries=0)
    assert client.call("chat.delete", max_retries=0)["ok"] is True

    assert server.calls == 2
    assert len(server.connections) == 2


def test_other_threads_get_their_own_connection(proxy):
    server = proxy()
    client = server.client()

    client.call("chat.delete", max_retries=0)
    other = threading.Thread(target=lambda: client.call("chat.delete", max_retries=0))
    other.start()
    other.join()

    assert len(server.connections) == 2


def test_a_refusal_still_raises_with_its_status(proxy):
    server = proxy(status=429)

    with pytest.raises(ProxyError) as caught:
        server.client().call("chat.delete", max_retries=0)

    assert caught.value.http_status == 429
    assert "budget: spent" in str(caught.value)


def test_nemo_admin_calls_keep_their_connection(monkeypatch):
    from bot.core import privileged

    monkeypatch.setenv("PROXY_TOKEN_NEMO", "t")
    monkeypatch.setenv("INTERNAL_PROXY_URL", "http://127.0.0.1:1")

    assert privileged.proxy().keep_alive is True


def test_a_kept_connection_turns_off_nagle(proxy):
    import socket

    server = proxy()
    server.client().call("chat.delete", max_retries=0)

    (conn, _at), = proxy_client._kept.pool.values()
    assert conn.sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY)
