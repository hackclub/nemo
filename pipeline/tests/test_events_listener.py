import jsonschema
import pytest

from ingest.events_listener import extract, load_schemas


def test_team_join_extraction_strips_the_profile_before_validation():
    schemas = load_schemas()
    raw_event = {
        "type": "team_join",
        "user": {
            "id": "U1",
            "team_id": "T1",
            "name": "someone",
            "real_name": "Some One",
            "is_bot": False,
            "profile": {
                "email": "someone@example.com",
                "real_name": "Some One",
                "image_192": "https://example.com/a.png",
            },
        },
        "event_ts": "1700000000.000100",
    }
    payload = extract(raw_event, schemas["team_join"])

    assert payload == {"user": {"id": "U1", "is_bot": False}, "event_ts": "1700000000.000100"}
    jsonschema.validate(payload, schemas["team_join"])


def test_schema_rejects_a_payload_that_still_carries_identity():
    schemas = load_schemas()
    leaked_payload = {
        "user": {"id": "U1", "profile": {"email": "someone@example.com"}},
        "event_ts": "1700000000.000100",
    }

    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(leaked_payload, schemas["team_join"])


def test_only_team_join_is_subscribed():
    assert set(load_schemas()) == {"team_join"}
