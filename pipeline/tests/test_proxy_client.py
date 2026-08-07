from lib.proxy_client import plaintext_refused


def test_https_anywhere_is_fine():
    assert plaintext_refused("https://proxy.example.com", allow_plaintext="") is None


def test_plaintext_to_loopback_is_fine():
    assert plaintext_refused("http://127.0.0.1:8002", allow_plaintext="") is None
    assert plaintext_refused("http://localhost:8002", allow_plaintext="") is None
    assert plaintext_refused("http://host.docker.internal:8002", allow_plaintext="") is None


def test_plaintext_to_another_machine_is_refused():
    refusal = plaintext_refused("http://proxy.example.com:8002", allow_plaintext="")
    assert "clear text" in refusal
    assert "proxy.example.com" in refusal


def test_plaintext_can_be_allowed_on_purpose():
    assert plaintext_refused("http://proxy.example.com", allow_plaintext="true") is None
    assert plaintext_refused("http://proxy.example.com", allow_plaintext="no") is not None
