from __future__ import annotations

import gzip
import http.client
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_HOST = "hackclub.slack.com"

_AUTH_ERRORS = {
    "invalid_auth",
    "not_authed",
    "token_revoked",
    "token_expired",
    "account_inactive",
    "no_permission",
}
_RETRY_STATUS = {429, 500, 502, 503, 504}


class InternalAuthError(RuntimeError):
    """The xoxc token or cookie is invalid or expired"""


class InternalApiError(RuntimeError):
    """The internal endpoint returned ok:false for a non-auth reason"""


class InternalClient:
    def __init__(self, token=None, cookie=None, host=None, slack_route=None):
        self.token = token or os.environ.get("SLACK_XOXC_TOKEN", "")
        self.cookie = cookie or os.environ.get("SLACK_D_COOKIE", "")
        self.host = host or os.environ.get("SLACK_WORKSPACE_HOST", DEFAULT_HOST)
        self.slack_route = slack_route or os.environ.get("SLACK_SLACK_ROUTE", "")
        if not self.token or not self.cookie:
            raise InternalAuthError("SLACK_XOXC_TOKEN and SLACK_D_COOKIE must both be set")

    def call(self, method, params=None, max_retries=3):
        body_params = {k: v for k, v in dict(params or {}).items() if v is not None}
        body_params["token"] = self.token
        body = urllib.parse.urlencode(body_params).encode()

        url = f"https://{self.host}/api/{method}"
        if self.slack_route:
            url += "?" + urllib.parse.urlencode({"slack_route": self.slack_route})
        headers = {
            "Content-Type": "application/x-www-form-urlencoded",
            "Cookie": f"d={self.cookie}",
        }

        data = self._request(url, body, headers, max_retries)
        if not data.get("ok", False):
            error = data.get("error", "unknown_error")
            if error in _AUTH_ERRORS:
                raise InternalAuthError(error)
            raise InternalApiError(error)
        return data

    def paginate(self, method, params, items_key, page_size=1000, cursor_param="cursor"):
        base = dict(params)
        base["count"] = page_size
        cursor = None
        seen = 0
        while True:
            page = dict(base)
            if cursor:
                page[cursor_param] = cursor
            data = self.call(method, page)
            items = data.get(items_key, [])
            yield from items
            seen += len(items)
            cursor = data.get("next_cursor_mark")
            num_found = data.get("num_found")
            if not cursor or not items:
                break
            if num_found is not None and seen >= num_found:
                break

    def _request(self, url, body, headers, max_retries):
        attempt = 0
        while True:
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    raw = resp.read()
                    if resp.headers.get("Content-Encoding") == "gzip":
                        raw = gzip.decompress(raw)
                    return json.loads(raw)
            except urllib.error.HTTPError as exc:
                if exc.code in _RETRY_STATUS and attempt < max_retries:
                    time.sleep(int(exc.headers.get("Retry-After", 1 + attempt)))
                    attempt += 1
                    continue
                raise
            except (urllib.error.URLError, http.client.IncompleteRead):
                if attempt < max_retries:
                    time.sleep(1 + attempt)
                    attempt += 1
                    continue
                raise
