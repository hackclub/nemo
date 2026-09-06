from lib import work


def test_a_unit_dies_only_at_the_attempt_cap():
    assert work.outcome_after_failure(1) == "pending"
    assert work.outcome_after_failure(work.MAX_ATTEMPTS - 1) == "pending"
    assert work.outcome_after_failure(work.MAX_ATTEMPTS) == "dead"
    assert work.outcome_after_failure(2, max_attempts=2) == "dead"


def test_positional_params_become_named_for_the_enqueue_select():
    assert work._positional(("a", 2)) == {"p0": "a", "p1": 2}
    sql = work.ENQUEUE_SQL.format(select="SELECT 1", conflict=work.CONFLICT_IGNORE)
    assert "'{}'::jsonb" in sql
    assert sql.rstrip().endswith("DO NOTHING")


def test_the_grown_conflict_never_touches_a_claimed_unit():
    assert "state <> 'claimed'" in work.CONFLICT_GROWN
    assert "EXCLUDED.expected > coalesce(ingest.work_item.fetched, 0)" in work.CONFLICT_GROWN
