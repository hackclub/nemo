from __future__ import annotations

import hashlib
import http.client
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

LOCAL_HOSTS = frozenset({"localhost", "127.0.0.1", "::1", "host.docker.internal"})
TRUTHY = frozenset({"1", "true", "yes", "on"})


class ProxyError(RuntimeError):
    """The proxy rejected the request: misconfiguration or a disallowed method"""


class ProxyUnavailableError(ProxyError):
    """The proxy could not be reached after retries"""


class InternalAuthError(RuntimeError):
    """The upstream Slack credential is invalid or expired"""


class InternalApiError(RuntimeError):
    """The upstream Slack endpoint returned ok:false for a non-auth reason"""


def plaintext_refused(url, allow_plaintext=None):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme == "https" or parsed.hostname in LOCAL_HOSTS:
        return None
    if allow_plaintext is None:
        allow_plaintext = os.environ.get("PROXY_ALLOW_PLAINTEXT", "")
    if allow_plaintext.strip().lower() in TRUTHY:
        return None
    return (
        f"INTERNAL_PROXY_URL is {parsed.scheme}:// to {parsed.hostname}, which sends the bearer "
        "token in clear text over the network. use https, or set PROXY_ALLOW_PLAINTEXT=true if "
        "that hop is already private"
    )


class ProxyClient:
    def __init__(self, url=None, token=None, read_timeout=120):
        self.url = (url or os.environ.get("INTERNAL_PROXY_URL", "")).rstrip("/")
        self.token = token or os.environ.get("INTERNAL_PROXY_TOKEN", "")
        self.read_timeout = read_timeout
        self.last_num_found = None
        if not self.url or not self.token:
            raise ProxyError("INTERNAL_PROXY_URL and INTERNAL_PROXY_TOKEN must both be set")
        refusal = plaintext_refused(self.url)
        if refusal:
            raise ProxyError(refusal)

    def call(self, method, params=None, max_retries=3, credential="internal"):
        payload = {
            "method": method,
            "params": {k: v for k, v in dict(params or {}).items() if v is not None},
            "credential": credential,
        }
        body = json.dumps(payload).encode()
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.token}",
        }
        return self._request(f"{self.url}/call", body, headers, max_retries)

    def fetch_file(self, method, params=None, max_retries=3, credential="admin"):
        payload = {
            "method": method,
            "params": {k: v for k, v in dict(params or {}).items() if v is not None},
            "credential": credential,
        }
        body = json.dumps(payload).encode()
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.token}",
        }
        return self._request(f"{self.url}/file", body, headers, max_retries, raw=True)

    def paginate(
        self,
        method,
        params,
        items_key,
        page_size=1000,
        cursor_param="cursor",
        max_retries=3,
        credential="internal",
        start_cursor=None,
        on_page=None,
        allow_empty_pages=False,
    ):
        base = dict(params)
        base["count"] = page_size
        cursor = start_cursor
        seen = 0
        previous_page = None
        while True:
            page = dict(base)
            if cursor:
                page[cursor_param] = cursor
            data = self.call(method, page, max_retries=max_retries, credential=credential)
            items = data.get(items_key, [])
            fingerprint = hashlib.sha256(
                json.dumps(items, sort_keys=True, default=str).encode()
            ).hexdigest()
            if items and fingerprint == previous_page:
                raise ProxyError(
                    f"{method}: page repeated after {seen} records, so the walk is not "
                    f"advancing. sort_column={base.get('sort_column')!r} is probably not "
                    f"unique enough for {cursor_param} to order stably"
                )
            previous_page = fingerprint

            yield from items
            seen += len(items)
            cursor = data.get("next_cursor_mark")
            num_found = data.get("num_found")
            if num_found is not None:
                self.last_num_found = num_found
            if on_page:
                on_page(cursor, seen)
            if not cursor or (not items and not allow_empty_pages):
                break
            if num_found is not None and seen >= num_found:
                break

    def _request(self, url, body, headers, max_retries, raw=False):
        attempt = 0
        while True:
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=self.read_timeout) as resp:
                    payload = resp.read()
                    return payload if raw else json.loads(payload)
            except urllib.error.HTTPError as exc:
                self._raise_for_status(exc)
            except (urllib.error.URLError, http.client.IncompleteRead, TimeoutError) as exc:
                if attempt < max_retries:
                    time.sleep(1 + attempt)
                    attempt += 1
                    continue
                raise ProxyUnavailableError(f"proxy unreachable at {self.url}: {exc}") from exc

    def _raise_for_status(self, exc):
        try:
            detail = json.loads(exc.read()).get("detail", "")
        except (ValueError, OSError):
            detail = ""

        if exc.code == 502:
            if str(detail).startswith("invalid_auth"):
                raise InternalAuthError(detail) from exc
            raise InternalApiError(detail or "upstream error") from exc
        raise ProxyError(f"proxy returned {exc.code}: {detail}") from exc
