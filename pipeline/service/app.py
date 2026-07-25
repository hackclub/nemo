import time
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException

from slack_sdk.errors import SlackApiError

from lib.internal_client import InternalApiError, InternalAuthError, InternalClient
from lib.slack_client import bot_client

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"
load_dotenv(ENV_FILE)

METHOD = "admin.analytics.getChannelAnalytics"
RANGE_METHOD = "admin.analytics.getAvailableDateRange"
app = FastAPI(title="mnemosyne channel-analytics")

_range_cache = {"value": None, "at": 0.0}


def available_range():
    if _range_cache["value"] and time.time() - _range_cache["at"] < 3600:
        return _range_cache["value"]
    resp = InternalClient().call(RANGE_METHOD, {"type": "member"})
    value = (resp["start_date"], resp["end_date"])
    _range_cache.update(value=value, at=time.time())
    return value


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/channel-members")
def channel_members(channel_id: str):
    try:
        resp = bot_client().conversations_info(channel=channel_id, include_num_members=True)
    except SlackApiError as exc:
        raise HTTPException(status_code=502, detail={"error": exc.response.get("error")}) from exc
    return {"num_members": resp["channel"].get("num_members")}


@app.get("/available-range")
def available_range_endpoint():
    try:
        start, end = available_range()
    except InternalAuthError as exc:
        raise HTTPException(status_code=503, detail={"error": "reauth", "message": str(exc)}) from exc
    except InternalApiError as exc:
        raise HTTPException(status_code=502, detail={"error": "api", "message": str(exc)}) from exc
    return {"start_date": start, "end_date": end}


@app.get("/channel-analytics")
def channel_analytics(channel_id: str, name: str, start: str, end: str, privacy: str = "public"):
    try:
        avail_start, avail_end = available_range()
        start = max(start, avail_start)
        end = min(end, avail_end)
        resp = InternalClient().call(METHOD, {
            "start_date": start,
            "end_date": end,
            "count": 100,
            "query": name,
            "privacy": privacy,
            "sort_column": "messages_count",
            "sort_direction": "desc",
        })
    except InternalAuthError as exc:
        raise HTTPException(status_code=503, detail={"error": "reauth", "message": str(exc)}) from exc
    except InternalApiError as exc:
        raise HTTPException(status_code=502, detail={"error": "api", "message": str(exc)}) from exc

    match = next(
        (c for c in resp.get("channel_analytics", []) if c.get("channel_id") == channel_id),
        None,
    )
    if match is None:
        raise HTTPException(status_code=404, detail={"error": "not_found"})

    return {
        "channel_id": match.get("channel_id"),
        "name": match.get("name"),
        "start_date": start,
        "end_date": end,
        "messages_count": match.get("messages_count"),
        "chats_count": match.get("chats_count"),
        "reactions_count": match.get("reactions_count"),
        "unique_posters": match.get("writers_count"),
        "unique_viewers": match.get("readers_count"),
        "unique_reactors": match.get("users_who_reacted_count"),
        "huddles_count": match.get("huddles_count"),
        "total_members_count": match.get("total_members_count"),
    }
