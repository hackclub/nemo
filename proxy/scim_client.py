import os

from slack_sdk.scim import SCIMClient

from slack_client import admin_token

UPSTREAM_TIMEOUT = 30
DEFAULT_BASE_URL = "https://api.slack.com/scim/v2/"

DEACTIVATE = "scim.users.deactivate"
ACTIVATE = "scim.users.activate"
METHODS = frozenset({DEACTIVATE, ACTIVATE})


class ScimError(RuntimeError):
    """SCIM answered with something other than success"""


def base_url():
    return os.environ.get("SLACK_SCIM_BASE_URL", "").strip() or DEFAULT_BASE_URL


def scim_client():
    token = admin_token()
    if not token:
        raise RuntimeError("the admin token must be set for SCIM")
    return SCIMClient(token=token, base_url=base_url(), timeout=UPSTREAM_TIMEOUT,
                      retry_handlers=[])


def user_id_of(params):
    said = str(params.get("user_id") or "").strip()
    if not said:
        raise ScimError("user_id is required")
    return said


def spoke(answer):
    errors = answer.errors
    if errors is not None:
        raise ScimError(f"scim {errors.code}: {errors.description}")
    if answer.status_code >= 400:
        raise ScimError(f"scim http {answer.status_code}: {answer.raw_body or ''}"[:500])
    return {"ok": True, "status": answer.status_code}


def call(method, params):
    client = scim_client()
    user_id = user_id_of(params)

    if method == DEACTIVATE:
        return spoke(client.delete_user(user_id))
    if method == ACTIVATE:
        return spoke(client.patch_user(user_id, {"active": True}))

    raise ScimError(f"unknown scim method: {method}")
