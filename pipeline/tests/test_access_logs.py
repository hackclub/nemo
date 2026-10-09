from datetime import UTC, datetime

from ingest import access_logs_pull

FIRST = 1790000000
LAST = 1790003600


def test_row_keeps_date_last_as_at_and_date_first_as_first_seen_at():
    row = access_logs_pull.row_for({"user_id": "U1", "date_first": FIRST, "date_last": LAST})

    assert row is not None
    assert row[1] == datetime.fromtimestamp(LAST, tz=UTC)
    assert row[-1] == datetime.fromtimestamp(FIRST, tz=UTC)


def test_row_without_date_first_leaves_first_seen_at_empty():
    row = access_logs_pull.row_for({"user_id": "U1", "date_last": LAST})

    assert row is not None
    assert row[-1] is None


def test_row_matches_the_insert_placeholders():
    row = access_logs_pull.row_for({"user_id": "U1", "date_first": FIRST, "date_last": LAST})

    assert row is not None
    assert access_logs_pull.ROW_SQL.count("%s") == len(row)


def test_upsert_keeps_the_earliest_first_seen_at():
    sql = access_logs_pull.ROW_SQL

    assert "first_seen_at = least(EXCLUDED.first_seen_at, fd.login_event.first_seen_at)" in sql
    assert "fd.login_event.first_seen_at)\n      IS DISTINCT FROM" in sql
