import pathlib

SQL = (pathlib.Path(__file__).parents[2] / "db" / "migrations" / "0201_evidence_snapshot.sql").read_text()


def test_every_fd_deactivation_freezes_the_evidence_on_its_guard():
    assert "AFTER INSERT ON fd.member_guard_events" in SQL
    assert "WHEN (NEW.verb = 'deactivated')" in SQL
    assert "'fire_engine', g.id, g.opened_by, g.reason" in SQL


def test_a_deactivation_done_in_slack_is_frozen_too_but_only_once():
    assert "AFTER INSERT ON slack.audit_event" in SQL
    assert "WHEN (NEW.action = 'user_deactivated')" in SQL
    assert "s.deactivated_at BETWEEN NEW.at - interval '1 hour' AND NEW.at + interval '1 hour'" in SQL


def test_an_old_deactivation_a_backfill_lands_is_not_frozen_with_todays_evidence():
    assert "NEW.at < now() - interval '1 day'" in SQL


def test_the_snapshot_holds_identity_cluster_traits_and_links():
    for part in ("'email', i.email", "FROM fd.member_cluster c", "FROM fd.member_trait t",
                 "FROM fd.member_link l", "'agent', a.ua"):
        assert part in SQL


def test_snapshots_are_kept_and_never_rewritten():
    assert "GRANT SELECT, INSERT ON fd.evidence_snapshot TO pipeline_writer" in SQL
    assert "UPDATE" not in SQL.split("GRANT", 1)[1].split("TO pipeline_writer")[0]
