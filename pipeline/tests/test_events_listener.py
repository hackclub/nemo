import jsonschema
import pytest

from ingest.events_listener import extract, load_schemas


def test_message_extraction_strips_text_before_validation():
    schemas = load_schemas()
    raw_event = {
        "type": "message",
        "user": "U1",
        "channel": "C1",
        "text": "some real message content that must never be stored",
        "ts": "1700000000.000100",
        "event_ts": "1700000000.000100",
    }
    payload = extract(raw_event, schemas["message"])
    assert "text" not in payload
    jsonschema.validate(payload, schemas["message"])


def test_schema_rejects_a_payload_that_still_has_text():
    schemas = load_schemas()
    leaked_payload = {
        "user": "U1",
        "channel": "C1",
        "ts": "1700000000.000100",
        "event_ts": "1700000000.000100",
        "text": "leaked content",
    }
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(leaked_payload, schemas["message"])


def test_extract_only_pulls_allowed_fields_for_channel_archive():
    schemas = load_schemas()
    raw_event = {"type": "channel_archive", "channel": "C1", "user": "U1", "actor_id": "U2"}
    payload = extract(raw_event, schemas["channel_archive"])
    assert payload == {"channel": "C1", "user": "U1"}


def test_extract_recurses_into_nested_channel_object():
    schemas = load_schemas()
    raw_event = {
        "type": "channel_created",
        "channel": {
            "id": "C1",
            "name": "general",
            "created": 1700000000,
            "creator": "U1",
            "is_general": True,
            "topic": {"value": "", "creator": "", "last_set": 0},
            "purpose": {"value": "", "creator": "", "last_set": 0},
            "previous_names": [],
        },
        "event_ts": "1700000000.000100",
    }
    payload = extract(raw_event, schemas["channel_created"])
    assert payload["channel"] == {"id": "C1", "name": "general", "created": 1700000000, "creator": "U1"}
    jsonschema.validate(payload, schemas["channel_created"])
