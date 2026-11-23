import base64
import os
from pathlib import Path

from slack_sdk.scim import SCIMClient

from slack_client import admin_token

UPSTREAM_TIMEOUT = 30
DEFAULT_BASE_URL = "https://api.slack.com/scim/v1/"

DEACTIVATE = "scim.users.deactivate"
ACTIVATE = "scim.users.activate"
REPLACE_PHOTO = "scim.users.photo.replace"
METHODS = frozenset({DEACTIVATE, ACTIVATE, REPLACE_PHOTO})

REPLACEMENT_PHOTO = Path(__file__).resolve().parent / "assets" / "sad_mac.png"


class ScimError(RuntimeError):
    """SCIM answered with something other than success"""


def base_url():
    return os.environ.get("SLACK_SCIM_BASE_URL", "").strip() or DEFAULT_BASE_URL


def scim_client():
    token = admin_token()
    if not token:
        raise RuntimeError("admin token not set")
    return SCIMClient(token=token, base_url=base_url(), timeout=UPSTREAM_TIMEOUT,
                      retry_handlers=[])


def user_id_of(params):
    value = str(params.get("user_id") or "").strip()
    if not value:
        raise ScimError("user_id is required")
    return value


def check_response(response):
    errors = response.errors
    if errors is not None:
        raise ScimError(f"scim {errors.code}: {errors.description}")
    if response.status_code >= 400:
        raise ScimError(f"scim http {response.status_code}: {response.raw_body or ''}"[:500])
    return {"ok": True, "status": response.status_code}


def replacement_photo_url():
    encoded = base64.b64encode(REPLACEMENT_PHOTO.read_bytes()).decode("ascii")
    return f"data:image/png;base64,{encoded}"


def call(method, params):
    client = scim_client()
    user_id = user_id_of(params)

    if method == DEACTIVATE:
        return check_response(client.delete_user(user_id))
    if method == ACTIVATE:
        return check_response(client.patch_user(user_id, {"active": True}))
    if method == REPLACE_PHOTO:
        photos = [{"value": replacement_photo_url(), "primary": True}]
        return check_response(client.patch_user(user_id, {"photos": photos}))

    raise ScimError(f"unknown scim method: {method}")
