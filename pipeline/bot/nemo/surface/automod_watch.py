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


def message_in(event):
    message = as_edited(event) if event.get("subtype") == EDITED else as_posted(event)
    if not message:
        return None
    if not message.get("user") or not message.get("channel") or not message.get("ts"):
        return None
    return message


@on_event("message", open_to_all=True)
def watched(ctx):
    message = message_in(ctx.payload or {})
    if not message:
        return None

    found = automod.caught(message.get("text"))
    if not found:
        return None

    with session() as conn:
        kept = [row[0] for row in
                (automod.record(conn, watch, message) for watch in found) if row]
        if not kept:
            return None
        automod.link(conn, kept, permalink_for(ctx.client, message["channel"], message["ts"]))

    log.info("nemo: automod caught %s word(s) in %s from %s",
             len(kept), message["ts"], message.get("user"))
    return len(kept)
