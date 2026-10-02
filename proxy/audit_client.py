import gzip
import json
import os
import urllib.error
import urllib.parse
import urllib.request

from slack_client import admin_token

DEFAULT_BASE_URL = "https://api.slack.com/audit/v1/"
UPSTREAM_TIMEOUT = 60

LOGS = "audit.logs"
ACTIONS = "audit.actions"
SCHEMAS = "audit.schemas"
METHODS = frozenset({LOGS, ACTIONS, SCHEMAS})

PATHS = {LOGS: "logs", ACTIONS: "actions", SCHEMAS: "schemas"}

WANTED = ("latest", "oldest", "limit", "action", "actor", "entity", "cursor")

MOST = 9999

AUTH_CODES = (401, 403)
REFUSAL_CODES = (400,)


class AuditAuthError(RuntimeError):
    """The token cannot read the audit logs: not org-installed, or the scope is missing"""


class AuditApiError(RuntimeError):
    """The audit endpoint refused for some other reason"""


def base_url():
    return os.environ.get("SLACK_AUDIT_BASE_URL", "").strip() or DEFAULT_BASE_URL


def limit_of(params):
    said = params.get("limit")
    if said in (None, ""):
        return None
    try:
        return max(1, min(int(said), MOST))
    except (TypeError, ValueError) as exc:
        raise AuditApiError(f"limit must be a number, got {said!r}") from exc


def query_for(params):
    asked = {}
    for key in WANTED:
        value = params.get(key)
        if value in (None, ""):
            continue
        asked[key] = str(value)

    capped = limit_of(params)
    if capped is not None:
        asked["limit"] = str(capped)
    return asked


def url_for(method, params):
    path = PATHS[method]
    asked = query_for(params) if method == LOGS else {}
    url = urllib.parse.urljoin(base_url(), path)
    return f"{url}?{urllib.parse.urlencode(asked)}" if asked else url


def body_of(answer):
    raw = answer.read()
    if answer.headers.get("Content-Encoding") == "gzip":
        raw = gzip.decompress(raw)
    return json.loads(raw.decode("utf-8"))


def call(method, params=None):
    if method not in METHODS:
        raise AuditApiError(f"unknown audit method: {method}")

    token = admin_token()
    if not token:
        raise AuditAuthError("the admin token must be set to read the audit logs")

    request = urllib.request.Request(
        url_for(method, params or {}),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )

    try:
        with urllib.request.urlopen(request, timeout=UPSTREAM_TIMEOUT) as answer:
            return body_of(answer)
    except urllib.error.HTTPError as failure:
        said = (failure.read() or b"").decode("utf-8", "replace")[:500]
        if failure.code in AUTH_CODES:
            raise AuditAuthError(f"audit {failure.code}: {said}") from failure
        if failure.code in REFUSAL_CODES:
            raise AuditApiError(f"audit {failure.code}: {said or 'refused'}") from failure
        raise
