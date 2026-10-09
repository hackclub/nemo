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


def finished(table):
    return dict(prune.FINISHED)[table]


def test_only_complete_work_is_pruned_so_a_given_up_target_is_not_queued_again():
    where = finished("ingest.work_item")
    assert "state = 'complete'" in where
    assert "coalesce(settled_at, updated_at) < now() - make_interval(days => %(days)s)" in where
    assert prune.FINISHED_DAYS == 90


def test_a_run_still_going_and_the_newest_run_of_each_source_are_kept():
    where = finished("raw.ingest_run")
    assert "status <> 'running'" in where
    assert "id NOT IN" in where and "parent_run_id NOT IN" in where
    newest = prune.NEWEST_RUNS
    assert "DISTINCT ON (source) id FROM raw.ingest_run ORDER BY source, started_at DESC" in newest
    assert "DISTINCT ON (source_key) id FROM raw.ingest_run WHERE source_key IS NOT NULL AND status = 'ok'" in newest


def test_step_output_goes_only_once_its_run_is_gone():
    assert ("NOT EXISTS (SELECT 1 FROM raw.ingest_run r WHERE r.id = ingest_step_output.parent_run_id)"
            in finished("raw.ingest_step_output"))


def test_runs_are_pruned_before_the_step_output_that_hangs_off_them():
    tables = [table for table, _ in prune.FINISHED]
    assert tables.index("raw.ingest_run") < tables.index("raw.ingest_step_output")


class Finished(Recorder):
    rowcount = 5


def test_a_dry_run_of_finished_rows_counts_and_never_deletes():
    conn = Finished(doomed=3)
    assert prune.sweep_finished(conn, "ingest.work_item", finished("ingest.work_item"), dry_run=True) == 3
    sql, params = conn.executed[0]
    assert sql.startswith("SELECT count(*) FROM ingest.work_item WHERE")
    assert params == {"days": 90}
    assert conn.committed is False


def test_finished_rows_are_deleted_and_committed():
    conn = Finished()
    assert prune.sweep_finished(conn, "ingest.work_item", finished("ingest.work_item")) == 5
    assert conn.executed[0][0].startswith("DELETE FROM ingest.work_item WHERE")
    assert conn.committed is True
