import logging

from psycopg.types.json import Jsonb

from bot.engine import session

log = logging.getLogger("bot.events")

LAND_SQL = """
INSERT INTO raw.event_delivery (event_id, event_type, channel_id, ts, event_ts, envelope)
VALUES (%s, %s, %s, %s, %s, %s)
ON CONFLICT (event_id) DO NOTHING
"""

REDACT = ("text", "blocks", "attachments", "files", "message", "previous_message")


def scrub(value):
    if isinstance(value, dict):
        return {k: scrub(v) for k, v in value.items() if k not in REDACT}
    if isinstance(value, list):
        return [scrub(v) for v in value]
    return value


def target(event):
    message = event.get("message") or {}
    return event.get("deleted_ts") or message.get("ts") or event.get("ts")


def land(event_id, event):
    if not event_id:
        return False
    try:
        with session() as conn, conn.cursor() as cur:
            cur.execute(LAND_SQL, (
                event_id,
                event.get("subtype") or event.get("type") or "unknown",
                event.get("channel"),
                target(event),
                event.get("event_ts"),
                Jsonb(scrub(event)),
            ))
        return True
    except Exception as exc:
        log.warning("events: could not land %s: %s", event_id, exc)
        return False
