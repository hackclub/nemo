import re
from dataclasses import dataclass

import psycopg
import yaml
from slack_sdk.errors import SlackApiError

from lib.paths import FAULTS_FILE
from lib.proxy_client import InternalApiError, InternalAuthError, ProxyError, ProxyUnavailableError
from lib.walk import WalkWrong

TABLE = yaml.safe_load(FAULTS_FILE.read_text())
CLASSES = TABLE["classes"]
SLACK_ERRORS = {error: name for name, errors in TABLE["slack_errors"].items() for error in errors}
PROXY_STATUS = re.compile(r"proxy returned (\d{3})")
DETAIL_LIMIT = 500
RAISED_BY_NAME = {"SyncCancelled": "cancelled", "SeededDeployment": "local", "LaneAborted": "local"}


@dataclass(frozen=True)
class Fault:
    name: str
    disposition: str
    detail: str

    def continues(self):
        return self.disposition == "continue"


def fault(name, exc):
    return Fault(name, CLASSES[name]["disposition"], str(exc)[:DETAIL_LIMIT])


def slack_error_of(exc):
    if isinstance(exc, SlackApiError):
        response = getattr(exc, "response", None) or {}
        return response.get("error") if hasattr(response, "get") else None
    return str(exc).split(":", 1)[0].strip()


def classify(exc):
    by_name = RAISED_BY_NAME.get(type(exc).__name__)
    if by_name:
        return fault(by_name, exc)
    if isinstance(exc, InternalAuthError):
        return fault("auth", exc)
    if isinstance(exc, ProxyUnavailableError):
        return fault("transport", exc)
    if isinstance(exc, ProxyError):
        matched = PROXY_STATUS.search(str(exc))
        code = int(matched.group(1)) if matched else None
        if code == 429:
            return fault("throttle", exc)
        if code in (502, 503, 504):
            return fault("transport", exc)
        if code == 401:
            return fault("auth", exc)
        return fault("local", exc)
    if isinstance(exc, (InternalApiError, SlackApiError)):
        return fault(SLACK_ERRORS.get(slack_error_of(exc) or "", "upstream"), exc)
    if isinstance(exc, (KeyError, ValueError, TypeError)):
        return fault("contract", exc)
    if isinstance(exc, (WalkWrong, psycopg.Error)):
        return fault("local", exc)
    if isinstance(exc, (TimeoutError, ConnectionError, OSError)):
        return fault("transport", exc)
    return fault("local", exc)
