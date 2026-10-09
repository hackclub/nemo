from ingest import member_links as links
from ingest import member_links_live as live


def test_a_value_held_by_more_than_any_ceiling_is_never_loaded():
    ceilings = [one.get("crowd_ceiling", 0) for one in links.signals().values()]
    assert live.CAP > max(ceilings)


def test_every_touched_member_brings_the_co_holders_whose_pairs_it_can_change():
    assert "WHERE v.people <= %(cap)s" in live.RESCORED
    assert "FROM touched_session s" in live.RESCORED
    assert "kind = 'inviter'" in live.RESCORED


def test_network_evidence_reads_whole_ranges_so_every_crowd_is_exact():
    assert "e.ip_prefix IN (SELECT ip_prefix FROM scope_prefix)" in live.SCOPE_LOGIN
    assert "e.ip_prefix NOT IN (SELECT ip_prefix FROM scope_prefix)" in live.SCOPE_LOGIN


def test_the_live_lane_reads_the_stored_shared_networks_and_whole_counts():
    assert live.LIVE["shared_ip"] == "fd.shared_ip"
    assert live.LIVE["crowded"] == "crowded"
    assert "fd.shared_ip" in live.LIVE["sighting"]


def test_the_country_check_reads_every_row_of_the_members_of_a_live_pair():
    assert "FROM fd.login_event WHERE user_id IN (SELECT a_user_id FROM link_pass" in live.LIVE["sighting"]


def test_only_pairs_with_a_rescored_member_are_written_or_swept():
    assert "a_user_id NOT IN (SELECT user_id FROM rescored)" in live.ONLY_RESCORED
    assert "l.a_user_id IN (SELECT user_id FROM rescored) OR l.b_user_id IN" in live.SWEEP


def test_a_member_touched_again_mid_pass_stays_queued():
    assert "t.touched_at = done.touched_at" in live.DONE_SQL


def test_the_lane_waits_for_a_full_rebuild_before_it_scores(capsys):
    class Conn:
        def execute(self, _sql, _args=None):
            return self

        def fetchall(self):
            return []

    assert live.run(Conn()) == 0
    assert "waiting for a full rebuild" in capsys.readouterr().out


def test_trait_changes_joins_and_bans_queue_the_member():
    import pathlib

    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations" / "0199_live_links.sql").read_text()
    assert "AFTER INSERT OR UPDATE OR DELETE ON fd.member_trait" in sql
    assert "AFTER INSERT OR UPDATE OF joined_at ON fd.member_joins" in sql
    assert "WHEN (NEW.action IN ('user_deactivated', 'user_reactivated'))" in sql
    assert "ON CONFLICT (user_id) DO UPDATE SET touched_at = EXCLUDED.touched_at" in sql
