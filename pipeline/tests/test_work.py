import re
import inspect
from unittest import mock

import pytest

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


def test_the_singleton_lock_is_session_scoped_and_namespaced():
    from lib import db

    assert db.SINGLETON_NAMESPACE == 8571
    source = inspect.getsource(db.sole_instance)
    assert "pg_try_advisory_lock" in source
    assert "pg_advisory_xact_lock" not in source
    assert "pg_advisory_unlock" in source
    assert "holder.close()" in source


def test_a_second_instance_is_refused_rather_than_left_to_double_the_budget():
    from lib import db

    class Taken:
        def execute(self, *_args):
            return self

        def fetchone(self):
            return (False,)

        def commit(self):
            pass

        def close(self):
            self.closed = True

    holder = Taken()
    with mock.patch.object(db, "connect", lambda *a, **k: holder):
        with pytest.raises(db.AlreadyRunning, match="double every in-process rate budget"):
            with db.sole_instance("archive_worker"):
                raise AssertionError("the body must not run")
    assert getattr(holder, "closed", False)


def test_the_sole_holder_runs_the_body_and_unlocks_after():
    from lib import db

    calls = []

    class Free:
        def execute(self, sql, *_args):
            calls.append("lock" if "try_advisory" in sql else "unlock")
            return self

        def fetchone(self):
            return (True,)

        def commit(self):
            pass

        def close(self):
            calls.append("close")

    with mock.patch.object(db, "connect", lambda *a, **k: Free()):
        with db.sole_instance("archive_worker"):
            calls.append("body")
    assert calls == ["lock", "body", "unlock", "close"]


def test_sweep_stale_runs_passes_one_parameter_per_placeholder():
    from lib import db

    src = inspect.getsource(db.sweep_stale_runs)
    sql = src[src.index('"""') + 3:src.rindex('"""')]
    assert sql.count("%s") == 2
    assert "format(" not in sql


def test_a_clean_settle_clears_the_attempt_count():
    from lib import work

    sql = work.SETTLE_SQL
    assert "attempts = CASE WHEN %(state)s = 'complete' THEN 0 ELSE attempts END" in sql


def test_a_short_settle_keeps_its_attempt_count():
    from lib import work

    assert "THEN 0 ELSE attempts END" in work.SETTLE_SQL
    assert "attempts = 0," not in work.SETTLE_SQL


def test_both_settle_paths_share_the_reset():
    from lib import work

    assert "SETTLE_SQL" in inspect.getsource(work.settle)
    assert "SETTLE_SQL" in inspect.getsource(work.settle_many)


def test_a_lifetime_claim_count_can_no_longer_exhaust_the_retry_budget():
    from lib import work

    claim_bumps = "attempts = w.attempts + 1" in work.CLAIM_SQL
    fail_caps = "attempts >= %(max_attempts)s" in work.FAIL_SQL
    settle_resets = "THEN 0 ELSE attempts END" in work.SETTLE_SQL
    assert claim_bumps and fail_caps and settle_resets


def test_the_failure_backoff_is_no_longer_identical_for_a_whole_batch():
    from lib import lease, work

    waits = {lease.backoff(3, base=30.0, cap=6 * 3600, spread=work.RETRY_SPREAD)
             for _ in range(200)}
    assert len(waits) > 100
    assert all(240.0 <= w <= 240.0 * (1 + work.RETRY_SPREAD) for w in waits)


def test_spread_is_proportional_so_it_still_matters_at_the_cap():
    from lib import lease

    short = [lease.backoff(0, base=30.0, cap=6 * 3600, spread=0.25) for _ in range(200)]
    long = [lease.backoff(20, base=30.0, cap=6 * 3600, spread=0.25) for _ in range(200)]
    assert (max(short) - min(short)) / 30.0 > 0.1
    assert (max(long) - min(long)) / 21600.0 > 0.1


def test_absolute_jitter_keeps_its_old_meaning():
    from lib import lease

    assert [lease.backoff(n) for n in range(4)] == [1.0, 2.0, 4.0, 8.0]
    assert 1.0 <= lease.backoff(0, jitter=0.5) <= 1.5


def test_a_reclaimed_lease_waits_instead_of_being_grabbed_again():
    from lib import work

    assert "next_attempt_at = now()," not in work.RECLAIM_SQL
    assert "make_interval" in work.RECLAIM_SQL
    assert "2 ^ lapses" in work.RECLAIM_SQL
    assert "random()" in work.RECLAIM_SQL


def test_reclaim_passes_a_parameter_for_every_placeholder():
    from lib import work

    names = set(re.findall(r"%\((\w+)\)s", work.RECLAIM_SQL))
    assert names == {"kind", "max_lapses", "lapse_base", "lapse_cap"}


def test_revive_clears_the_lapse_count_so_it_is_not_born_condemned():
    from lib import work

    assert "attempts = 0, lapses = 0" in work.REVIVE_SQL


def test_the_abandon_sweep_outlasts_the_nightly_budget():
    from unittest import mock

    from lib import db

    with mock.patch.object(db.settings, "budget_minutes", return_value=720):
        assert db.stale_after_hours(object()) == 14
    with mock.patch.object(db.settings, "budget_minutes", return_value=60):
        assert db.stale_after_hours(object()) == db.STALE_AFTER_HOURS


def test_the_sweep_message_quotes_the_threshold_it_actually_used():
    import inspect

    from lib import db

    src = inspect.getsource(db.sweep_stale_runs)
    assert "if max_age_hours is None" in src
    assert "stale_after_hours(conn)" in src


def test_the_build_wait_can_be_dialled_without_a_deploy():
    import os
    from unittest import mock

    from lib import db

    with mock.patch.dict(os.environ, {"NEMO_BUILD_WAIT_SECONDS": "45"}):
        assert db.build_wait_seconds() == 45
    with mock.patch.dict(os.environ, {"NEMO_BUILD_WAIT_SECONDS": ""}):
        assert db.build_wait_seconds() == db.BUILD_WAIT_SECONDS
