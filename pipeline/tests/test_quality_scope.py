import inspect

from jobs import invariants, nightly_sync, reconcile


def test_i11_grades_only_the_day_sources_the_walk_writes():
    body = inspect.getsource(invariants.i11_every_day_source_is_recent)
    assert "DAY_LEDGERS" in body
    assert "source = ANY(%s)" in body


def test_i11_ignores_a_finished_import():
    walked = [day_source for day_source, _ in invariants.DAY_LEDGERS]
    assert "member_day_import" not in walked


def test_r6_counts_only_units_revive_should_have_taken_and_did_not():
    from lib import work

    assert reconcile.STUCK_AFTER_HOURS == 2 * work.REVIVE_HOURS
    assert "next_attempt_at IS NULL" in reconcile.DEAD_SQL
    assert f"make_interval(hours => {reconcile.STUCK_AFTER_HOURS})" in reconcile.DEAD_SQL


def test_r6_ignores_the_units_revive_is_meant_to_leave_dead():
    assert "<> 'entity:'" in reconcile.DEAD_SQL
    assert "<> ALL(%s::text[])" in reconcile.DEAD_SQL


def test_r6_uses_the_same_refusals_revive_does():
    from lib import work

    body = inspect.getsource(reconcile.r6_dead_units)
    assert "work.REFUSALS" in body
    assert "channel_not_found" in work.REFUSALS


def test_prometheans_opens_a_run_like_every_other_stage():
    body = inspect.getsource(nightly_sync.reconcile_prometheans)
    assert "ingest_run(conn, PROMETHEANS)" in body
    assert "counts.rows_in" in body


def test_the_prometheans_stage_hands_the_connection_over():
    entries = {name: stage for name, stage in nightly_sync.stages()}
    assert nightly_sync.PROMETHEANS in entries
