from contextlib import contextmanager
from datetime import UTC, datetime

import pytest

from ingest import access_logs_pull
from lib import user_agents

FIRST = 1790000000
LAST = 1790003600
MARKER = 1780000000


class Counts:
    rows_in = 0
    rows_rejected = 0


class FakeClient:
    def __init__(self, pages):
        self.pages = pages
        self.params = None

    def paginate(self, _method, params, _items_key, on_page=None, **_kwargs):
        self.params = params

        def entries():
            seen = 0
            for page in self.pages:
                yield from page
                seen += len(page)
                if on_page:
                    on_page("next", seen)

        return entries()


class FakeConn:
    def __init__(self, oldest=None):
        self.oldest = oldest

    def execute(self, _sql, _params=None):
        return self

    def fetchone(self):
        return (self.oldest,)

    def commit(self):
        pass


def entry(first_seen):
    return {"user_id": "U1", "date_first": first_seen, "date_last": first_seen}


@pytest.fixture
def walk(monkeypatch):
    state = {"marker": None, "saved": []}

    @contextmanager
    def bookkeeping(*_args, **_kwargs):
        yield Counts()

    monkeypatch.setattr(access_logs_pull, "ingest_run", bookkeeping)
    monkeypatch.setattr(access_logs_pull, "insert_rows", lambda _conn, logins, _counts: len(logins))
    monkeypatch.setattr(access_logs_pull, "get_cursor",
                        lambda _conn, _key, max_age_hours=None: state["marker"])
    monkeypatch.setattr(access_logs_pull, "save_cursor",
                        lambda _conn, _key, value: state["saved"].append(value))
    return state


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
    assert access_logs_pull.ROW_SQL.count("%s") == len(access_logs_pull.landing_row(row, {}))


def test_a_sign_in_lands_in_the_utc_hour_of_its_last_sighting():
    row = access_logs_pull.row_for({"user_id": "U1", "date_first": FIRST, "date_last": LAST,
                                    "ip": "1.2.3.4", "user_agent": "Mozilla/5.0 agent"})
    landed = access_logs_pull.landing_row(row, {user_agents.digest("Mozilla/5.0 agent"): 7})

    last = datetime.fromtimestamp(LAST, tz=UTC)
    assert landed[1] == last.replace(minute=0, second=0)
    assert landed[3] == 7
    assert landed[4:6] == (last, last)


def test_upsert_keeps_the_earliest_first_seen_at():
    sql = access_logs_pull.ROW_SQL

    assert "first_seen_at = least(EXCLUDED.first_seen_at, held.first_seen_at)" in sql
    assert "held.isp)\n      IS DISTINCT FROM" in sql


def test_a_sighting_counts_only_when_it_moves_the_hour_s_range():
    assert ("hits = held.hits + CASE WHEN EXCLUDED.last_at > held.last_at OR EXCLUDED.first_at < held.first_at"
            in access_logs_pull.ROW_SQL)


def test_backfill_starts_at_the_oldest_held_sign_in_without_a_marker(walk):
    client = FakeClient([[entry(FIRST)]])

    access_logs_pull.backfill(FakeConn(datetime.fromtimestamp(LAST, tz=UTC)), client)

    assert client.params == {"before": LAST}


def test_backfill_with_nothing_held_starts_from_now(walk):
    client = FakeClient([])
    started = int(datetime.now(UTC).timestamp())

    access_logs_pull.backfill(FakeConn(), client)

    assert client.params is not None
    assert started <= client.params["before"] <= started + 60


def test_backfill_resumes_from_the_saved_marker(walk):
    walk["marker"] = str(MARKER)
    client = FakeClient([])

    access_logs_pull.backfill(FakeConn(datetime.fromtimestamp(LAST, tz=UTC)), client)

    assert client.params == {"before": MARKER}


def test_backfill_saves_the_oldest_first_seen_after_each_page(walk):
    walk["marker"] = str(MARKER)
    client = FakeClient([[entry(MARKER - 10), entry(MARKER - 20)], [entry(MARKER - 30)]])

    landed = access_logs_pull.backfill(FakeConn(), client)

    assert landed == 3
    assert walk["saved"][:2] == [str(MARKER - 20), str(MARKER - 30)]
    assert walk["saved"][-1] == access_logs_pull.BACKFILL_COMPLETE


def test_a_capped_pass_keeps_its_place_and_stays_incomplete(walk, monkeypatch):
    monkeypatch.setattr(access_logs_pull, "PAGE", 2)
    monkeypatch.setattr(access_logs_pull, "MOST_PAGES", 1)
    walk["marker"] = str(MARKER)
    client = FakeClient([[entry(MARKER - 10), entry(MARKER - 20)], [entry(MARKER - 30)]])

    landed = access_logs_pull.backfill(FakeConn(), client)

    assert landed == 2
    assert walk["saved"][-1] == str(MARKER - 20)
    assert access_logs_pull.BACKFILL_COMPLETE not in walk["saved"]


def test_an_empty_walk_marks_the_backfill_complete(walk):
    walk["marker"] = str(MARKER)

    landed = access_logs_pull.backfill(FakeConn(), FakeClient([[]]))

    assert landed == 0
    assert walk["saved"] == [access_logs_pull.BACKFILL_COMPLETE]


def test_a_complete_backfill_makes_no_request(walk):
    walk["marker"] = access_logs_pull.BACKFILL_COMPLETE
    client = FakeClient([[entry(MARKER)]])

    assert access_logs_pull.backfill(FakeConn(), client) == 0
    assert client.params is None
    assert walk["saved"] == []


def test_next_before_moves_back_when_every_entry_shares_the_start_second():
    start = datetime.fromtimestamp(MARKER, tz=UTC)
    older = datetime.fromtimestamp(MARKER - 5, tz=UTC)

    assert access_logs_pull.next_before(MARKER, start) == MARKER - 1
    assert access_logs_pull.next_before(MARKER, older) == MARKER - 5
