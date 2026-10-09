from datetime import UTC, datetime, timedelta

from ingest import member_clusters as clusters
from lib.graph import components

RULE = {"min_accounts": 4, "window_minutes": 60}


def at(minute, hour=10):
    return datetime(2026, 10, 2, hour, 0, tzinfo=UTC) + timedelta(minutes=minute)


def test_components_join_chains_and_put_the_largest_first():
    assert components([("U1", "U2"), ("U3", "U2"), ("U7", "U8")]) == [{"U1", "U2", "U3"}, {"U7", "U8"}]


def test_a_burst_is_the_most_accounts_inside_one_window():
    window = timedelta(minutes=60)

    assert clusters.burst([at(0), at(10), at(50), at(55), at(200)], window) == 4
    assert clusters.burst([at(0), at(100), at(200)], window) == 1
    assert clusters.burst([None, at(5), None], window) == 1
    assert clusters.burst([], window) == 0


def test_a_cluster_is_named_after_its_oldest_account():
    joined = {"U9": at(30), "U2": at(0), "U5": None}

    assert clusters.oldest({"U9", "U2", "U5"}, joined) == "U2"
    assert clusters.oldest({"U5", "U4"}, {}) == "U4"


def test_four_accounts_joining_within_an_hour_make_a_ring_and_active_ones_are_marked():
    group = {"U1", "U2", "U3", "U4"}
    accounts = {"U1": (False, at(0)), "U2": (True, at(5)), "U3": (False, at(20)), "U4": (False, at(40))}

    rows = clusters.cluster_rows([group], accounts, RULE)

    assert {row[1] for row in rows} == {"U1"}
    assert all(row[2] == 4 and row[3] and not row[5] for row in rows)
    assert [row[0] for row in rows if row[4]] == ["U2"]


def test_accounts_spread_over_days_are_a_cluster_but_not_a_ring():
    group = {"U1", "U2", "U3", "U4"}
    accounts = {one: (True, at(0, hour)) for one, hour in zip(sorted(group), (1, 5, 9, 13), strict=True)}

    rows = clusters.cluster_rows([group], accounts, RULE)

    assert not any(row[3] for row in rows)


def test_household_and_classroom_links_never_join_a_cluster():
    assert "NOT (l.label = ANY(%(unclustered)s))" in clusters.EDGES_SQL
    assert set(clusters.UNCLUSTERED_LABELS) == {"household", "classroom"}


def test_clusters_build_on_strong_links_only():
    assert clusters.settings()["edge_score"] >= 5.0
    assert "score >= %(edge)s" in clusters.EDGES_SQL


def test_an_unchanged_cluster_row_is_not_written_again():
    assert "IS DISTINCT FROM" in clusters.LAND
    assert clusters.SWEEP.startswith("DELETE FROM fd.member_cluster WHERE NOT (user_id = ANY")


def test_a_same_person_verdict_joins_clusters_and_a_different_people_verdict_cuts_its_link():
    sql = clusters.EDGES_SQL

    assert "UNION\nSELECT a_user_id, b_user_id FROM fd.member_link_verdict WHERE verdict = ANY(%(together)s)" in sql
    assert "v.verdict = ANY(%(apart)s)" in sql
    assert set(clusters.TOGETHER) == {"same_person", "staff_test"}
    assert set(clusters.APART) == {"different_people", "household"}


def test_two_clusters_bridged_by_a_verdict_become_one():
    groups = components([("U1", "U2"), ("U3", "U4"), ("U2", "U3")])

    assert groups == [{"U1", "U2", "U3", "U4"}]


def test_a_cluster_still_holding_two_accounts_fd_called_different_people_is_flagged():
    accounts = {one: (True, at(i)) for i, one in enumerate(["U1", "U2", "U3"])}

    flagged = clusters.cluster_rows([{"U1", "U2", "U3"}], accounts, RULE, apart=[("U1", "U3")])
    clean = clusters.cluster_rows([{"U1", "U2", "U3"}], accounts, RULE, apart=[("U1", "U9")])

    assert all(row[5] for row in flagged)
    assert not any(row[5] for row in clean)


def test_a_conflict_change_is_written_like_any_other_change():
    assert "conflict = EXCLUDED.conflict" in clusters.LAND
    assert "EXCLUDED.conflict)" in clusters.LAND
