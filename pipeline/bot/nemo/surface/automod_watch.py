import logging

from bot.core import session
from bot.nemo import automod
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")

CARRIES = (None, "file_share", "me_message", "thread_broadcast")
EDITED = "message_changed"


def permalink_for(client, channel_id, ts):
    try:
        return (client.chat_getPermalink(channel=channel_id, message_ts=ts) or {}).get("permalink")
    except Exception as failure:
        log.info("nemo: no permalink for %s in %s: %s", ts, channel_id, failure)
        return None


def as_posted(event):
    if event.get("subtype") not in CARRIES or event.get("bot_id"):
        return None
    return event


def as_edited(event):
    message = event.get("message") or {}
    if message.get("bot_id") or message.get("subtype") not in CARRIES:
        return None
    return {
        "user": message.get("user"),
        "channel": event.get("channel"),
        "ts": message.get("ts"),
        "thread_ts": message.get("thread_ts"),
        "text": message.get("text"),
    }


def said_in(event):
    said = as_edited(event) if event.get("subtype") == EDITED else as_posted(event)
    if not said:
        return None
    if not said.get("user") or not said.get("channel") or not said.get("ts"):
        return None
    return said


@on_event("message", open_to_all=True)
def watched(ctx):
    said = said_in(ctx.payload or {})
    if not said:
        return None

    found = automod.caught(said.get("text"))
    if not found:
        return None

    with session() as conn:
        kept = [row[0] for row in
                (automod.record(conn, watch, said) for watch in found) if row]
        if not kept:
            return None
        automod.link(conn, kept, permalink_for(ctx.client, said["channel"], said["ts"]))

    log.info("nemo: automod caught %s word(s) in %s from %s",
             len(kept), said["ts"], said.get("user"))
    return len(kept)
