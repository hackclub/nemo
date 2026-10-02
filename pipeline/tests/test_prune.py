from ingest import prune
from lib import settings


def test_the_day_sources_share_a_table_stamp_that_is_not_their_run_name():
    assert prune.stamp_of("member_days") == "admin_analytics_api"
    assert prune.stamp_of("channel_days") == "admin_analytics_api"


def test_single_source_tables_keep_their_own_key_as_stamp():
    assert prune.stamp_of("channel_membership") == "channel_membership"


def test_the_coverage_ledger_is_never_pruned():
    assert "raw.analytics_day" not in prune.AGED_BY


def test_windows_scope_shared_tables_by_source_and_leave_private_ones_alone(monkeypatch):
    monkeypatch.setattr(settings, "retention_days", lambda conn, key: 400)
    asked = prune.windows(conn=None)
    by_table = {(key, table): stamp for key, table, _, _, stamp in asked}
    assert by_table[("member_days", "raw.member_activity_snapshot")] == "admin_analytics_api"
    assert by_table[("channel_days", "raw.channel_activity_snapshot")] == "admin_analytics_api"
    assert by_table[("channel_membership", "raw.member_channel_membership")] is None
    assert not any(table == "raw.analytics_day" for _, table, _, _, _ in asked)


def test_windows_is_empty_when_no_retention_is_set(monkeypatch):
    monkeypatch.setattr(settings, "retention_days", lambda conn, key: None)
    assert prune.windows(conn=None) == []


class Recorder:
    def __init__(self, doomed=0):
        self.doomed = doomed
        self.executed = []
        self.committed = False

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, params):
        self.executed.append((sql, params))

    def fetchone(self):
        return (self.doomed,)

    def commit(self):
        self.committed = True


def test_sweep_adds_a_source_predicate_for_a_shared_table():
    conn = Recorder(doomed=0)
    prune.sweep(conn, "member_days", "raw.member_activity_snapshot", "window_start", 400,
                stamp="admin_analytics_api", dry_run=True)
    sql, params = conn.executed[0]
    assert "AND source = %s" in sql
    assert params == (400, "admin_analytics_api")


def test_sweep_has_no_source_predicate_for_a_private_table():
    conn = Recorder(doomed=0)
    prune.sweep(conn, "channel_membership", "raw.member_channel_membership", "seen_at", 60,
                stamp=None, dry_run=True)
    sql, params = conn.executed[0]
    assert "source" not in sql
    assert params == (60,)


def test_a_dry_run_counts_but_never_deletes():
    conn = Recorder(doomed=12)
    gone = prune.sweep(conn, "member_days", "raw.member_activity_snapshot", "window_start", 400,
                       stamp="admin_analytics_api", dry_run=True)
    assert gone == 12
    assert len(conn.executed) == 1
    assert conn.committed is False
