import json
import os
from pathlib import Path

import jsonschema
from dotenv import load_dotenv
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

from lib.db import connect, dead_letter

ENV_FILE = Path(__file__).resolve().parents[2] / "infra" / ".env"
SCHEMA_DIR = Path(__file__).resolve().parents[2] / "schemas" / "raw_events"
SOURCE = "events_listener"

SCHEMA_FILES = {
    "message": "message.json",
    "reaction_added": "reaction_added.json",
    "member_joined_channel": "member_joined_channel.json",
    "member_left_channel": "member_left_channel.json",
    "team_join": "team_join.json",
    "channel_created": "channel_created.json",
    "channel_archive": "channel_archive.json",
    "channel_unarchive": "channel_unarchive.json",
    "channel_rename": "channel_rename.json",
}


def load_schemas():
    return {name: json.loads((SCHEMA_DIR / fname).read_text()) for name, fname in SCHEMA_FILES.items()}


def extract(event, schema):
    if not isinstance(event, dict):
        return event
    result = {}
    for key, subschema in schema.get("properties", {}).items():
        if key not in event:
            continue
        if subschema.get("type") == "object" and "properties" in subschema:
            result[key] = extract(event[key], subschema)
        else:
            result[key] = event[key]
    return result


def handle_event(conn, schemas, event_type, event):
    payload = extract(event, schemas[event_type])
    try:
        jsonschema.validate(payload, schemas[event_type])
    except jsonschema.ValidationError as exc:
        dead_letter(conn, SOURCE, {"event_type": event_type, "payload": payload}, str(exc))
        conn.commit()
        return
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO raw.slack_events (event_type, payload) VALUES (%s, %s)",
            (event_type, json.dumps(payload)),
        )
    conn.commit()


def make_handler(conn, schemas, event_type):
    def handler(event):
        handle_event(conn, schemas, event_type, event)

    return handler


def build_app(conn, schemas):
    app = App(token=os.environ["SLACK_BOT_TOKEN"])

    for event_type in SCHEMA_FILES:
        app.event(event_type)(make_handler(conn, schemas, event_type))

    return app


def main():
    load_dotenv(ENV_FILE)
    schemas = load_schemas()
    with connect() as conn:
        app = build_app(conn, schemas)
        SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"]).start()


if __name__ == "__main__":
    main()
