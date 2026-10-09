import pathlib

import pytest

from ingest import member_links as links

WHOLE = 1000


def rarity(crowd, whole=WHOLE):
    import math
    if whole <= 2 or crowd <= 1:
        return 1.0
    if crowd >= whole:
        return 0.0
    return min(1.0, max(0.0, math.log(whole / crowd) / math.log(whole / 2)))


def score_for(name, crowd, whole=WHOLE):
    return links.signals()[name]["weight"] * rarity(crowd, whole)


def test_every_signal_carries_a_weight_a_label_and_a_ceiling():
    for name, one in links.signals().items():
        assert one["weight"] > 0, name
        assert one["label"], name
        assert one["crowd_ceiling"] >= 2, name


def test_the_bands_climb():
    marks = links.scoring()
    assert marks["floor"] < marks["strong"] < marks["certain"]


def test_a_value_only_two_people_share_scores_the_whole_weight():
    assert score_for("ip_exact", 2) == pytest.approx(5.0)
    assert score_for("ip_prefix", 2) == pytest.approx(3.0)


def test_a_value_a_crowd_shares_is_worth_almost_nothing():
    assert score_for("ip_prefix", 20) < 2.1
    assert score_for("email_domain", 30) < 1.4


def test_a_school_domain_cannot_link_two_people_on_its_own():
    marks = links.scoring()
    assert score_for("email_domain", 6) < marks["floor"], \
        "six people on one domain is a school, not an alt"
    assert score_for("joined_together", 2) < marks["floor"], \
        "arriving together is a crowd signal, not an identity"


def test_two_weak_signals_together_do_reach_the_floor():
    marks = links.scoring()
    together = score_for("email_domain", 6) + score_for("joined_together", 2)
    assert together >= marks["floor"]


def test_one_address_two_people_is_the_strongest_thing_we_have():
    marks = links.scoring()
    assert score_for("ip_exact", 2) >= marks["strong"]


def test_the_agent_only_corroborates_so_a_shared_browser_links_nobody():
    assert links.corroborating() == ["session_agent"]
    assert "session_agent" not in [
        name for name, one in links.signals().items() if not one.get("corroborating")
    ]


def test_the_landing_refuses_a_pair_held_up_by_corroboration_alone():
    assert "NOT (signal = ANY (%(corroborating)s))" in links.LAND
    assert "> 0" in links.LAND


def test_a_pair_is_written_one_way_round_so_it_cannot_be_held_twice():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0149_member_links.sql").read_text()
    assert "CHECK (a_user_id < b_user_id)" in sql
    assert "PRIMARY KEY (a_user_id, b_user_id)" in sql
    assert "least(a.user_id, b.user_id)" in links.PAIRS_SQL


def test_a_verdict_is_held_once_per_pair_in_the_same_order_as_its_link():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0181_member_link_verdicts.sql").read_text()
    assert "CHECK (a_user_id < b_user_id)" in sql
    assert "UNIQUE (a_user_id, b_user_id)" in sql


def test_a_link_nothing_supports_any_more_is_swept_rather_than_left_standing():
    assert links.SWEEP.startswith("DELETE FROM fd.member_link")
    assert "computed_at <" in links.SWEEP


def test_the_crowd_ceiling_prunes_before_the_join_not_after_it():
    for sql in (links.PAIRS_SQL, links.TOGETHER_SQL):
        pruned = sql.index("BETWEEN 2 AND %(ceiling)s")
        joined = sql.index("JOIN small b")
        assert pruned < joined, (
            "a value thousands of people share must be dropped before the self-join; "
            "filtering after it materialises n squared rows and the pass never ends")
        assert "FROM small a" in sql


def test_neither_side_of_the_join_reads_the_unpruned_evidence():
    for sql in (links.PAIRS_SQL, links.TOGETHER_SQL):
        assert "FROM ev a" not in sql
        assert "JOIN ev b" not in sql


def test_a_network_many_people_share_is_not_evidence_of_anything():
    held = links.shared()
    assert held["rotates_above"] > 1, "a carrier hands each person a fresh address every time"
    assert held["crowds_above"] > 1, "a vpn exit is one address behind which anybody can stand"
    assert held["min_sightings"] >= 2, "one sighting on an address is a coincidence, not a home"


def test_the_shared_networks_are_worked_out_rather_than_listed_by_hand():
    assert "count(DISTINCT ip)" in links.SHARED_ISP
    assert "count(DISTINCT user_id)" in links.SHARED_ISP
    assert "rotates" in links.SHARED_ISP and "crowds" in links.SHARED_ISP
    for named in ("T-Mobile", "ProtonVPN", "Jio"):
        assert named not in links.SHARED_ISP, "no isp is named in the code"


def test_an_address_on_a_shared_network_never_reaches_the_evidence():
    for name in (links.IP_EXACT, links.IP_PREFIX):
        assert "NOT EXISTS (SELECT 1 FROM shared_ip" in links.EVIDENCE[name]


def test_an_address_seen_once_is_not_enough_to_call_it_theirs():
    for name in (links.IP_EXACT, links.IP_PREFIX):
        assert "HAVING count(*) >= {sightings}" in links.EVIDENCE[name]


def test_the_floor_clears_a_single_weak_signal():
    marks = links.scoring()
    assert marks["floor"] > links.signals()["ip_prefix"]["weight"] * 0.9, \
        "a shared /24 on its own must not be enough to link two people"


def test_the_shared_tables_are_gone_when_the_pass_commits():
    assert "ON COMMIT DROP" in links.SHARED_ISP
    assert "ON COMMIT DROP" in links.SHARED_IP


def test_every_signal_the_catalogue_names_can_actually_be_gathered():
    known = set(links.EVIDENCE) | {links.JOINED_TOGETHER}
    assert set(links.signals()) <= known
