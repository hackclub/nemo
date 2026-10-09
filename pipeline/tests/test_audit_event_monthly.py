import pathlib

SQL = (pathlib.Path(__file__).parents[2] / "db" / "migrations" / "0189_audit_event_monthly.sql").read_text()


def test_events_are_partitioned_by_month_and_keyed_with_the_month():
    assert "PARTITION BY RANGE (at)" in SQL
    assert "PRIMARY KEY (id, at)" in SQL
    assert "id           uuid" in SQL


def test_the_values_searched_on_have_typed_columns():
    for column in ("category", "actor_email", "entity_email", "channel_id", "ip           inet",
                   "ua_id        integer", "session_id   bigint"):
        assert column in SQL, column
    assert "context" not in SQL
    assert "tsvector" not in SQL


def test_payloads_compress_with_lz4_on_every_month():
    assert SQL.count("SET COMPRESSION lz4") == 3
    assert "toast_tuple_target" not in SQL


def test_user_agents_are_stored_once():
    assert "REFERENCES slack.user_agent (id)" in SQL
    assert "ON slack.user_agent (md5(ua))" in SQL


def test_months_are_created_ahead_and_odd_dates_still_land():
    assert "PARTITION OF slack.audit_event_monthly DEFAULT" in SQL
    assert "SELECT slack.ensure_audit_event_months('2025-11-01', 2);" in SQL
    assert "00:00:00+00" in SQL
