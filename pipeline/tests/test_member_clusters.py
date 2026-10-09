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
    assert all(row[2] == 4 and row[3] for row in rows)
    assert [row[0] for row in rows if row[4]] == ["U2"]


def test_accounts_spread_over_days_are_a_cluster_but_not_a_ring():
    group = {"U1", "U2", "U3", "U4"}
    accounts = {one: (True, at(0, hour)) for one, hour in zip(sorted(group), (1, 5, 9, 13), strict=True)}

    rows = clusters.cluster_rows([group], accounts, RULE)

    assert not any(row[3] for row in rows)


def test_household_and_classroom_links_never_join_a_cluster():
    assert "NOT (label = ANY(%(unclustered)s))" in clusters.EDGES_SQL
    assert set(clusters.UNCLUSTERED_LABELS) == {"household", "classroom"}


def test_clusters_build_on_strong_links_only():
    assert clusters.settings()["edge_score"] >= 5.0
    assert "score >= %(edge)s" in clusters.EDGES_SQL


def test_an_unchanged_cluster_row_is_not_written_again():
    assert "IS DISTINCT FROM" in clusters.LAND
    assert clusters.SWEEP.startswith("DELETE FROM fd.member_cluster WHERE NOT (user_id = ANY")
