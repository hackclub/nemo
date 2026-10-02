from __future__ import annotations

import hashlib
import http.client
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

from lib.deadline import Deadline

LOCAL_HOSTS = frozenset({"localhost", "127.0.0.1", "::1", "host.docker.internal"})
TRUTHY = frozenset({"1", "true", "yes", "on"})
EMPTY_PAGE_LIMIT = 40
EMPTY_PAGE_BACKOFF = 2.0
EMPTY_PAGE_BACKOFF_CAP = 20.0


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


RETRY_STATUS = frozenset({429, 502, 503, 504})
UPSTREAM_TRANSPORT = ("upstream unreachable", "upstream timeout", "upstream http")
FAULT_ORIGIN_HEADER = "X-Fault-Origin"


class ProxyClient:
    def __init__(self, url=None, token=None, read_timeout=120, deadline_seconds=None):
        self.url = (url or os.environ.get("INTERNAL_PROXY_URL", "")).rstrip("/")
        self.token = token or os.environ.get("INTERNAL_PROXY_TOKEN", "")
        self.read_timeout = read_timeout
        self.deadline_seconds = deadline_seconds if deadline_seconds is not None else read_timeout
        self.last_num_found = None
        if not self.url or not self.token:
            raise ProxyError("INTERNAL_PROXY_URL and INTERNAL_PROXY_TOKEN must both be set")
        refusal = plaintext_refused(self.url)
        if refusal:
            raise ProxyError(refusal)

    @classmethod
    def for_source(cls, key, **kwargs):
        from lib import sources
        budget = sources.unit_budget_seconds(key)
        return cls(deadline_seconds=budget, read_timeout=min(120, budget), **kwargs)

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

    def verify(self, timeout=30):
        req = urllib.request.Request(
            f"{self.url}/verify",
            headers={"Authorization": f"Bearer {self.token}"},
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            try:
                return json.loads(exc.read())
            except (ValueError, OSError):
                raise ProxyError(f"proxy returned {exc.code} from /verify") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ProxyUnavailableError(f"proxy unreachable at {self.url}: {exc}") from exc

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
        page_param="count",
        cursor_field="next_cursor_mark",
    ):
        base = dict(params)
        base[page_param] = page_size
        cursor = start_cursor
        seen = 0
        previous_page = None
        empty_pages = 0
        while True:
            asked_with = cursor
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
            if cursor_field == "response_metadata.next_cursor":
                cursor = (data.get("response_metadata") or {}).get("next_cursor")
            else:
                cursor = data.get(cursor_field)
            num_found = data.get("num_found")
            if num_found is not None:
                self.last_num_found = num_found
            empty_pages = empty_pages + 1 if not items else 0
            if empty_pages and allow_empty_pages:
                time.sleep(min(EMPTY_PAGE_BACKOFF * empty_pages, EMPTY_PAGE_BACKOFF_CAP))
            if on_page:
                on_page(cursor, seen)
            if not cursor or (not items and not allow_empty_pages):
                break
            if cursor == asked_with:
                raise ProxyError(
                    f"{method}: {cursor_param} came back unchanged after {seen} records, "
                    f"so the next request would repeat this one"
                )
            if empty_pages >= EMPTY_PAGE_LIMIT:
                raise ProxyError(
                    f"{method}: {empty_pages} empty pages in a row after {seen} records, "
                    f"so the walk has stalled short of the {num_found} it expected"
                )
            if num_found is not None and seen >= num_found:
                break

    def _request(self, url, body, headers, max_retries, raw=False):
        deadline = Deadline(self.deadline_seconds)
        attempt = 0
        while True:
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            timeout = deadline.clamp(self.read_timeout)
            if timeout <= 0:
                raise ProxyUnavailableError(
                    f"deadline of {deadline.seconds:.0f}s spent after {attempt} attempt(s) at {self.url}")
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    payload = resp.read()
                    return payload if raw else json.loads(payload)
            except urllib.error.HTTPError as exc:
                if exc.code in RETRY_STATUS and attempt < max_retries and not deadline.expired():
                    time.sleep(deadline.clamp(retry_after(exc, 1 + attempt)))
                    attempt += 1
                    continue
                self._raise_for_status(exc)
            except (urllib.error.URLError, http.client.IncompleteRead, TimeoutError) as exc:
                if attempt < max_retries and not deadline.expired():
                    time.sleep(deadline.clamp(1 + attempt))
                    attempt += 1
                    continue
                raise ProxyUnavailableError(
                    f"proxy unreachable at {self.url} after {attempt + 1} attempt(s): {exc}") from exc

    def _raise_for_status(self, exc):
        try:
            detail = json.loads(exc.read()).get("detail", "")
        except (ValueError, OSError):
            detail = ""
        from_proxy = exc.headers.get(FAULT_ORIGIN_HEADER) is not None

        if exc.code in (502, 504) and str(detail).startswith(UPSTREAM_TRANSPORT):
            raise stamped(ProxyUnavailableError(f"proxy could not reach slack: {detail}"), exc.code, from_proxy) from exc
        if exc.code == 502:
            if str(detail).startswith("invalid_auth"):
                raise stamped(InternalAuthError(detail), exc.code, from_proxy) from exc
            raise stamped(InternalApiError(detail or "upstream error"), exc.code, from_proxy) from exc
        raise stamped(ProxyError(f"proxy returned {exc.code}: {detail}"), exc.code, from_proxy) from exc


def retry_after(exc, fallback):
    try:
        return max(0.0, float(exc.headers.get("Retry-After", fallback)))
    except (TypeError, ValueError):
        return float(fallback)


def stamped(error, http_status, had_fault_body):
    error.http_status = http_status
    error.had_fault_body = had_fault_body
    return error
