import inspect

from ingest import dim_snapshot


def test_neither_snapshot_stamps_the_wall_clock_date():
    for sql in (dim_snapshot.MEMBER_SQL, dim_snapshot.CHANNEL_SQL):
        assert "current_date" not in sql, (
            "a nightly that crosses midnight would file the snapshot under the wrong day"
        )
        assert "%(observed_on)s" in sql


def test_the_snapshot_day_comes_from_the_run_it_belongs_to():
    assert "logical_date" in dim_snapshot.LOGICAL_DATE_SQL
    body = inspect.getsource(dim_snapshot.run)
    assert "LOGICAL_DATE_SQL" in body
    assert "counts.run_id" in body


def test_both_snapshots_are_stamped_with_the_same_day():
    body = inspect.getsource(dim_snapshot.run)
    assert body.count('{"observed_on": observed_on}') == 2
