from checks import table_growth

MB = 1024 * 1024


def test_a_day_is_flagged_past_twice_the_median():
    assert table_growth.flagged(500 * MB, 200 * MB, 30)
    assert not table_growth.flagged(390 * MB, 200 * MB, 30)


def test_small_tables_are_never_flagged_below_the_floor():
    assert not table_growth.flagged(90 * MB, 1 * MB, 30)
    assert table_growth.flagged(120 * MB, 1 * MB, 30)
    assert table_growth.limit(None) == table_growth.FLOOR_BYTES


def test_a_table_needs_a_week_of_history_before_it_can_be_flagged():
    assert not table_growth.flagged(900 * MB, 1 * MB, table_growth.FEWEST_DAYS - 1)
    assert table_growth.flagged(900 * MB, 1 * MB, table_growth.FEWEST_DAYS)


def test_a_shrinking_or_unmeasured_table_is_not_flagged():
    assert not table_growth.flagged(-900 * MB, 10 * MB, 30)
    assert not table_growth.flagged(None, 10 * MB, 30)


def test_each_flagged_table_is_its_own_incident_and_the_summary_never_is():
    marked = [(500 * MB, 100 * MB, True, "slack.audit_event"), (1 * MB, 1 * MB, False, "fd.member")]

    found = table_growth.results(marked)

    assert found[0] == ("slack.audit_event grows under twice its 30-day median", "error", "fail",
                        "grew 500 MB in a day", "under 200 MB")
    assert found[-1][1:4] == ("info", "warn", "1 of 2 table(s) flagged")
    assert len(found) == 2


def test_a_quiet_night_records_one_passing_summary():
    assert table_growth.results([(1 * MB, 1 * MB, False, "fd.member")]) == [
        ("no table grows past twice its 30-day median", "info", "pass", "0 of 1 table(s) flagged", "0 flagged")]


def test_growth_is_per_day_even_when_a_night_was_missed():
    assert "/ nullif(day - lag(day) OVER held, 0)" in table_growth.GROWTH_SQL


def test_a_partitioned_table_is_measured_as_the_sum_of_its_months():
    sql = table_growth.SNAPSHOT_SQL
    assert "pg_partition_tree(c.oid) WHERE c.relkind = 'p'" in sql
    assert "NOT c.relispartition" in sql
