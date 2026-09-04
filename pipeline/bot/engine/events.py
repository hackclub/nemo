import json
import logging
import os
import threading
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb

from bot.engine import session

log = logging.getLogger("bot.events")

SPILL_ENV = "SPINE_SPILL_FILE"
SPILL_DEFAULT = Path("/tmp/nemo-spine-spill.jsonl")
SPILL_LOCK = threading.Lock()

NEVER = (psycopg.ProgrammingError, psycopg.DataError, psycopg.IntegrityError)


def spill_file():
    named = os.environ.get(SPILL_ENV)
    return Path(named) if named else SPILL_DEFAULT


def stuck_file():
    return spill_file().with_suffix(".stuck.jsonl")


def spill(row):
    try:
        with SPILL_LOCK:
            with spill_file().open("a", encoding="utf-8") as out:
                out.write(json.dumps(row, default=str) + "\n")
    except Exception as exc:
        log.error("events: could not spill %s, it is lost: %s", row[0], exc)


def set_aside(lines):
    try:
        with stuck_file().open("a", encoding="utf-8") as out:
            out.write("\n".join(lines) + "\n")
    except Exception as exc:
        log.error("events: could not set aside %d line(s): %s", len(lines), exc)


def drain():
    with SPILL_LOCK:
        path = spill_file()
        if not path.exists():
            return 0

        kept = [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        landed, waiting, hopeless = 0, [], []
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
            except NEVER as exc:
                log.error("events: spilled %s will never land, setting it aside: %s", row[0], exc)
                hopeless.append(line)
            except Exception as exc:
                log.warning("events: spilled %s still will not land: %s", row[0], exc)
                waiting.append(line)

        if hopeless:
            set_aside(hopeless)
        if waiting:
            path.write_text("\n".join(waiting) + "\n", encoding="utf-8")
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


def channel_of(event):
    named = event.get("channel")
    return named.get("id") if isinstance(named, dict) else named


def row_for(event_id, event):
    return (
        event_id,
        event.get("subtype") or event.get("type") or "unknown",
        channel_of(event),
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
    except NEVER as exc:
        log.error("events: %s can never land, setting it aside: %s", event_id, exc)
        with SPILL_LOCK:
            set_aside([json.dumps(row, default=str)])
        return False
    except Exception as exc:
        log.warning("events: could not land %s, spilling it: %s", event_id, exc)
        spill(row)
        return False
