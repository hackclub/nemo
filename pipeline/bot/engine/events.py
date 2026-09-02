import json
import logging
import os
import threading
from pathlib import Path

from psycopg.types.json import Jsonb

from bot.engine import session

log = logging.getLogger("bot.events")

SPILL_ENV = "SPINE_SPILL_FILE"
SPILL_DEFAULT = Path("/tmp/nemo-spine-spill.jsonl")
SPILL_LOCK = threading.Lock()


def spill_file():
    named = os.environ.get(SPILL_ENV)
    return Path(named) if named else SPILL_DEFAULT


def spill(row):
    try:
        with SPILL_LOCK:
            with spill_file().open("a", encoding="utf-8") as out:
                out.write(json.dumps(row, default=str) + "\n")
    except Exception as exc:
        log.error("events: could not spill %s, it is lost: %s", row[0], exc)


def drain():
    path = spill_file()
    if not path.exists():
        return 0

    with SPILL_LOCK:
        kept = [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        landed, stuck = 0, []
        for line in kept:
            try:
                row = json.loads(line)
            except ValueError:
                log.error("events: a spilled line will not parse, dropping it")
                continue
            try:
                with session() as conn:
                    write(conn, row)
                landed += 1
            except Exception as exc:
                log.warning("events: spilled %s still will not land: %s", row[0], exc)
                stuck.append(line)

        if stuck:
            path.write_text("\n".join(stuck) + "\n", encoding="utf-8")
        else:
            path.unlink(missing_ok=True)

    if landed:
        log.info("events: landed %s spilled event(s)", landed)
    return landed

LAND_SQL = """
INSERT INTO raw.event_delivery (event_id, event_type, channel_id, ts, event_ts, envelope)
VALUES (%s, %s, %s, %s, %s, %s)
ON CONFLICT (event_id) DO NOTHING
"""

REDACT = ("text", "blocks", "attachments", "files", "message", "previous_message", "profile")

USER_KEPT = ("id", "team_id", "is_bot", "is_admin", "deleted", "updated")


def thin_user(value):
    if not isinstance(value, dict):
        return value
    return {k: v for k, v in value.items() if k in USER_KEPT}


def scrub(value):
    if isinstance(value, dict):
        return {
            k: (thin_user(v) if k == "user" else scrub(v))
            for k, v in value.items()
            if k not in REDACT
        }
    if isinstance(value, list):
        return [scrub(v) for v in value]
    return value


def target(event):
    message = event.get("message") or {}
    return event.get("deleted_ts") or message.get("ts") or event.get("ts")


def row_for(event_id, event):
    return (
        event_id,
        event.get("subtype") or event.get("type") or "unknown",
        event.get("channel"),
        target(event),
        event.get("event_ts"),
        scrub(event),
    )


def write(conn, row):
    channel, ts, event_ts, envelope = row[2], row[3], row[4], row[5]
    with conn.cursor() as cur:
        cur.execute(LAND_SQL, (row[0], row[1], channel, ts, event_ts, Jsonb(envelope)))


def land(event_id, event):
    if not event_id:
        return False

    row = row_for(event_id, event)
    try:
        with session() as conn:
            write(conn, row)
        return True
    except Exception as exc:
        log.warning("events: could not land %s, spilling it: %s", event_id, exc)
        spill(row)
        return False
