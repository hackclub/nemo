from lib import work


def test_a_unit_dies_only_at_the_attempt_cap():
    assert work.outcome_after_failure(1) == "pending"
    assert work.outcome_after_failure(work.MAX_ATTEMPTS - 1) == "pending"
    assert work.outcome_after_failure(work.MAX_ATTEMPTS) == "dead"
    assert work.outcome_after_failure(2, max_attempts=2) == "dead"


def test_a_killed_worker_costs_a_lapse_not_an_attempt():
    assert work.outcome_after_lapse(0) == "pending"
    assert work.outcome_after_lapse(work.MAX_LAPSES - 2) == "pending"
    assert work.outcome_after_lapse(work.MAX_LAPSES - 1) == "dead"
    assert work.outcome_after_lapse(1, max_lapses=2) == "dead"
    assert work.MAX_LAPSES > work.MAX_ATTEMPTS


def test_reclaim_gives_the_attempt_back_and_counts_a_lapse():
    assert "attempts = greatest(attempts - 1, 0)" in work.RECLAIM_SQL
    assert "lapses = lapses + 1" in work.RECLAIM_SQL
    assert "lapses + 1 >= %(max_lapses)s" in work.RECLAIM_SQL
    assert "max_attempts" not in work.RECLAIM_SQL


def test_positional_params_become_named_for_the_enqueue_select():
    assert work._positional(("a", 2)) == {"p0": "a", "p1": 2}
    sql = work.ENQUEUE_SQL.format(select="SELECT 1", conflict=work.CONFLICT_IGNORE)
    assert "'{}'::jsonb" in sql
    assert sql.rstrip().endswith("DO NOTHING")


def test_the_grown_conflict_never_touches_a_claimed_unit():
    assert "state <> 'claimed'" in work.CONFLICT_GROWN
    assert "EXCLUDED.expected > coalesce(ingest.work_item.fetched, 0)" in work.CONFLICT_GROWN
