from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException

from lib.internal_client import InternalApiError, InternalAuthError, InternalClient

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"
load_dotenv(ENV_FILE)

METHOD = "admin.analytics.getChannelAnalytics"
app = FastAPI(title="mnemosyne channel-analytics")


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/channel-analytics")
def channel_analytics(channel_id: str, name: str, start: str, end: str, privacy: str = "public"):
    try:
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
