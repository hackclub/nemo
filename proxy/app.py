import logging
import os
import secrets
from contextlib import asynccontextmanager
from pathlib import Path

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from slack_sdk.errors import SlackApiError

from internal_client import InternalApiError, InternalAuthError, InternalClient
from slack_client import AUTH_ERRORS, admin_client

ENV_FILE = Path(__file__).resolve().parent / ".env"
load_dotenv(ENV_FILE)

ALLOWED_METHODS = {
    "internal": frozenset(
        {
            "admin.analytics.getMemberAnalytics",
            "admin.analytics.getAvailableDateRange",
            "admin.analytics.getChannelAnalytics",
            "team.stats.timeSeries",
        }
    ),
    "admin": frozenset(
        {
            "admin.users.list",
            "admin.teams.list",
            "admin.analytics.messages.activity",
        }
    ),
}

ALLOWED_FILE_METHODS = frozenset({"admin.analytics.getFile"})

CREDENTIALS = ("internal", "admin")

logger = logging.getLogger("uvicorn.error")


def credential_present(name):
    if name == "internal":
        return bool(os.environ.get("SLACK_XOXC_TOKEN") and os.environ.get("SLACK_D_COOKIE"))
    return bool(os.environ.get("SLACK_ADMIN_TOKEN"))


def whoami(name):
    try:
        if name == "internal":
            data = InternalClient().call("auth.test")
        else:
            data = admin_client().auth_test().data
    except (InternalAuthError, InternalApiError, RuntimeError) as exc:
        return {"ok": False, "error": str(exc)}
    except SlackApiError as exc:
        return {"ok": False, "error": exc.response.get("error", "unknown_error")}
    return {
        "ok": bool(data.get("ok")),
        "user": data.get("user"),
        "user_id": data.get("user_id"),
        "team": data.get("team"),
        "team_id": data.get("team_id"),
    }


@asynccontextmanager
async def lifespan(_app):
    for name in CREDENTIALS:
        if not credential_present(name):
            logger.error("%s credential MISSING from the environment", name)
            continue
        info = whoami(name)
        if info["ok"]:
            logger.info(
                "%s credential ok: %s (%s) on %s / %s",
                name, info["user"], info["user_id"], info["team"], info["team_id"],
            )
        else:
            logger.error("%s credential FAILED: %s", name, info["error"])
    logger.info(
        "allowlist: internal=%d admin=%d file=%d",
        len(ALLOWED_METHODS["internal"]), len(ALLOWED_METHODS["admin"]), len(ALLOWED_FILE_METHODS),
    )
    yield


app = FastAPI(lifespan=lifespan)
bearer = HTTPBearer(auto_error=False)


def require_token(creds: HTTPAuthorizationCredentials | None = Depends(bearer)):
    expected = os.environ.get("PROXY_TOKEN", "")
    if not expected:
        raise HTTPException(status_code=503, detail="proxy token is not configured")
    if creds is None or not secrets.compare_digest(
        creds.credentials.encode("utf-8"), expected.encode("utf-8")
    ):
        raise HTTPException(status_code=401, detail="invalid bearer token")


class CallRequest(BaseModel):
    method: str
    params: dict = {}
    credential: str = "internal"
    max_retries: int = 3


@app.get("/verify", dependencies=[Depends(require_token)])
def verify(response: Response):
    credentials = {}
    for name in CREDENTIALS:
        if not credential_present(name):
            credentials[name] = {"ok": False, "error": "not configured"}
            continue
        credentials[name] = whoami(name)

    ok = all(c["ok"] for c in credentials.values())
    if not ok:
        response.status_code = 503
    return {
        "ok": ok,
        "credentials": credentials,
        "allowed_methods": {k: sorted(v) for k, v in ALLOWED_METHODS.items()},
        "allowed_file_methods": sorted(ALLOWED_FILE_METHODS),
    }


def call_internal(req: CallRequest):
    try:
        client = InternalClient()
    except InternalAuthError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    try:
        return client.call(req.method, req.params, max_retries=req.max_retries)
    except InternalAuthError as exc:
        raise HTTPException(status_code=502, detail=f"invalid_auth: {exc}") from exc
    except InternalApiError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


def admin_api_call(method, params):
    try:
        client = admin_client()
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    try:
        return client.api_call(method, params=params)
    except SlackApiError as exc:
        error = exc.response.get("error", "unknown_error")
        if error in AUTH_ERRORS:
            raise HTTPException(status_code=502, detail=f"invalid_auth: {error}") from exc
        raise HTTPException(status_code=502, detail=error) from exc


def call_admin(req: CallRequest):
    return admin_api_call(req.method, req.params).data


@app.post("/file", dependencies=[Depends(require_token)])
def file(req: CallRequest):
    if req.method not in ALLOWED_FILE_METHODS:
        raise HTTPException(
            status_code=403, detail=f"method not allowed for file transfer: {req.method}"
        )

    raw = admin_api_call(req.method, req.params).data
    if not isinstance(raw, (bytes, bytearray)):
        raise HTTPException(status_code=502, detail=f"expected a file body, got {type(raw).__name__}")
    return Response(content=bytes(raw), media_type="application/octet-stream")


@app.post("/call", dependencies=[Depends(require_token)])
def call(req: CallRequest):
    allowed = ALLOWED_METHODS.get(req.credential)
    if allowed is None:
        raise HTTPException(status_code=400, detail=f"unknown credential: {req.credential}")
    if req.method not in allowed:
        raise HTTPException(
            status_code=403,
            detail=f"method not allowed for {req.credential} credential: {req.method}",
        )

    if req.credential == "admin":
        return call_admin(req)
    return call_internal(req)
