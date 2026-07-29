import os
from pathlib import Path

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from internal_client import InternalApiError, InternalAuthError, InternalClient

ENV_FILE = Path(__file__).resolve().parent / ".env"
load_dotenv(ENV_FILE)

ALLOWED_METHODS = frozenset(
    {
        "admin.analytics.getMemberAnalytics",
        "admin.analytics.getAvailableDateRange",
        "admin.analytics.getChannelAnalytics",
        "team.stats.timeSeries",
    }
)

app = FastAPI()
bearer = HTTPBearer(auto_error=False)


def require_token(creds: HTTPAuthorizationCredentials | None = Depends(bearer)):
    expected = os.environ.get("PROXY_TOKEN", "")
    if not expected:
        raise HTTPException(status_code=503, detail="proxy token is not configured")
    if creds is None or creds.credentials != expected:
        raise HTTPException(status_code=401, detail="invalid bearer token")


class CallRequest(BaseModel):
    method: str
    params: dict = {}
    max_retries: int = 3


@app.get("/health")
def health():
    return {
        "ok": True,
        "credential_configured": bool(
            os.environ.get("SLACK_XOXC_TOKEN") and os.environ.get("SLACK_D_COOKIE")
        ),
        "allowed_methods": sorted(ALLOWED_METHODS),
    }


@app.post("/call", dependencies=[Depends(require_token)])
def call(req: CallRequest):
    if req.method not in ALLOWED_METHODS:
        raise HTTPException(status_code=403, detail=f"method not allowed: {req.method}")

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
