import http.client
import logging
import os
import secrets
import socket
import time
import urllib.error
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse

import budget
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from slack_sdk.errors import SlackApiError

from internal_client import InternalApiError, InternalAuthError, InternalClient
from slack_client import AUTH_ERRORS, admin_client, admin_token

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
            "search.messages",
            "conversations.history",
            "conversations.replies",
            "conversations.members",
        }
    ),
}

ALLOWED_FILE_METHODS = frozenset({"admin.analytics.getFile"})

WEB_METHODS = {
    "internal": frozenset(
        {
            "admin.analytics.getChannelAnalytics",
            "admin.analytics.getAvailableDateRange",
        }
    ),
}

CREDENTIALS = ("internal", "admin")


@dataclass(frozen=True)
class Client:
    name: str
    methods: dict
    file_methods: frozenset


CLIENTS = (
    ("pipeline", "PROXY_TOKEN", ALLOWED_METHODS, ALLOWED_FILE_METHODS),
    ("web", "PROXY_TOKEN_WEB", WEB_METHODS, frozenset()),
)

logger = logging.getLogger("uvicorn.error")


def credential_present(name):
    if name == "internal":
        return bool(os.environ.get("SLACK_XOXC_TOKEN") and os.environ.get("SLACK_D_COOKIE"))
    return bool(admin_token())


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
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": f"unreachable: {type(exc).__name__}: {exc}"}
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
    for name, var, methods, file_methods in CLIENTS:
        if not os.environ.get(var, ""):
            logger.warning("client %s has no token in %s, so it cannot call the proxy", name, var)
            continue
        logger.info(
            "client %s: %d methods, %d file methods",
            name, sum(len(v) for v in methods.values()), len(file_methods),
        )
    yield


app = FastAPI(lifespan=lifespan)
bearer = HTTPBearer(auto_error=False)


def current_client(creds: HTTPAuthorizationCredentials | None = Depends(bearer)) -> Client:
    matched = None
    configured = 0
    presented = creds.credentials.encode("utf-8") if creds else b""
    for name, var, methods, file_methods in CLIENTS:
        token = os.environ.get(var, "")
        if not token:
            continue
        configured += 1
        if creds and secrets.compare_digest(presented, token.encode("utf-8")):
            matched = Client(name, methods, file_methods)
    if not configured:
        raise HTTPException(status_code=503, detail="no proxy client token is configured")
    if matched is None:
        raise HTTPException(status_code=401, detail="invalid bearer token")
    return matched


MAX_RETRIES_CEILING = 8


class CallRequest(BaseModel):
    method: str
    params: dict = {}
    credential: str = "internal"
    max_retries: int = Field(3, ge=0, le=MAX_RETRIES_CEILING)


@app.get("/health")
def health():
    return {
        "ok": True,
        "credentials": {name: credential_present(name) for name in CREDENTIALS},
    }


VERIFY_CACHE_SECONDS = 60
_verify_cache = {"at": 0.0, "credentials": None}


def credentials_report():
    now = time.monotonic()
    cached = _verify_cache["credentials"]
    if cached is not None and now - _verify_cache["at"] < VERIFY_CACHE_SECONDS:
        return cached
    credentials = {}
    for name in CREDENTIALS:
        if not credential_present(name):
            credentials[name] = {"ok": False, "error": "not configured"}
            continue
        credentials[name] = whoami(name)
    _verify_cache["at"] = now
    _verify_cache["credentials"] = credentials
    return credentials


@app.get("/verify")
def verify(response: Response, client: Client = Depends(current_client)):
    credentials = credentials_report()
    ok = all(c["ok"] for c in credentials.values())
    if not ok:
        response.status_code = 503
    failing = [f"{name}: {state.get('error') or 'not ok'}" for name, state in credentials.items() if not state["ok"]]
    return {
        "ok": ok,
        "detail": None if ok else "; ".join(failing),
        "client": client.name,
        "credentials": credentials,
        "allowed_methods": {k: sorted(v) for k, v in client.methods.items()},
        "allowed_file_methods": sorted(client.file_methods),
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
        if exc.response.status_code == 429:
            raise HTTPException(
                status_code=429,
                detail=f"upstream {error}",
                headers={"Retry-After": str(exc.response.headers.get("Retry-After", "1"))},
            ) from exc
        if error in AUTH_ERRORS:
            raise HTTPException(status_code=502, detail=f"invalid_auth: {error}") from exc
        raise HTTPException(status_code=502, detail=error) from exc


def call_admin(req: CallRequest):
    return admin_api_call(req.method, req.params).data


@app.post("/file")
def file(req: CallRequest, client: Client = Depends(current_client)):
    if req.method not in client.file_methods:
        raise HTTPException(
            status_code=403,
            detail=f"method not allowed for file transfer by {client.name}: {req.method}",
        )

    raw = admin_api_call(req.method, req.params).data
    if not isinstance(raw, (bytes, bytearray)):
        raise HTTPException(status_code=502, detail=f"expected a file body, got {type(raw).__name__}")
    return Response(content=bytes(raw), media_type="application/octet-stream")


@app.post("/call")
def call(req: CallRequest, client: Client = Depends(current_client)):
    if req.credential not in CREDENTIALS:
        raise HTTPException(status_code=400, detail=f"unknown credential: {req.credential}")
    if req.method not in client.methods.get(req.credential, frozenset()):
        raise HTTPException(
            status_code=403,
            detail=(
                f"method not allowed for {client.name} on the "
                f"{req.credential} credential: {req.method}"
            ),
        )

    refused = budget.take(client.name, req.credential, req.method)
    if refused:
        wait, label = refused
        raise HTTPException(
            status_code=429,
            detail=f"budget: {label} is spent, retry in {wait}s",
            headers={"Retry-After": str(wait)},
        )

    if req.credential == "admin":
        return call_admin(req)
    return call_internal(req)


@app.get("/budget")
def budget_report(client: Client = Depends(current_client)):
    return budget.report()


TRANSPORT_ERRORS = (urllib.error.URLError, http.client.IncompleteRead, ConnectionError, OSError)
FAULT_ORIGIN = "X-Fault-Origin"


@app.exception_handler(Exception)
async def upstream_escaped(request: Request, exc: Exception):
    if isinstance(exc, urllib.error.HTTPError):
        if exc.code == 429:
            return JSONResponse(
                status_code=429,
                content={"detail": "upstream ratelimited"},
                headers={"Retry-After": exc.headers.get("Retry-After", "1"), FAULT_ORIGIN: "proxy"},
            )
        status, detail = 502, f"upstream http {exc.code}: {exc.reason}"
    elif isinstance(exc, (TimeoutError, socket.timeout)):
        status, detail = 504, f"upstream timeout: {exc}"
    elif isinstance(exc, TRANSPORT_ERRORS):
        status, detail = 502, f"upstream unreachable: {type(exc).__name__}: {exc}"
    elif isinstance(exc, ValueError):
        status, detail = 502, f"upstream returned a body that was not JSON: {exc}"
    else:
        status, detail = 500, f"{type(exc).__name__}: {exc}"
    logger.error("escaped into the catch-all: %s", detail)
    return JSONResponse(status_code=status, content={"detail": detail[:500]}, headers={FAULT_ORIGIN: "proxy"})


@app.middleware("http")
async def fault_origin(request: Request, call_next):
    response = await call_next(request)
    if response.status_code >= 400:
        response.headers[FAULT_ORIGIN] = "proxy"
    return response
