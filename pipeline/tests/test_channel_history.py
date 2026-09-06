from ingest import channel_history_pull as history


def test_tail_walks_forward_from_the_lookback_and_backfill_walks_older_ward_exclusive():
    assert history.walk_params("C1") == {"channel": "C1"}
    assert history.walk_params("C1", oldest="1700000000.000100") == {"channel": "C1", "oldest": "1700000000.000100"}
    assert history.walk_params("C1", latest="1600000000.000000") == {
        "channel": "C1", "latest": "1600000000.000000", "inclusive": False,
    }


def test_revisit_from_steps_back_one_lookback_and_never_below_zero():
    assert history.revisit_from("1700000000.000000") == f"{1700000000 - history.LOOKBACK_SECONDS:.6f}"
    assert history.revisit_from("10.000000") == "0.000000"
    assert history.revisit_from("not a ts") == "not a ts"


def test_enqueue_selects_name_both_kinds_and_only_unfinished_channels_for_backfill():
    assert "coalesce(w.history_complete, false) = false" in history.BACKFILL_SELECT
    assert "d.archived IS NOT TRUE" in history.TAIL_SELECT
    assert history.BACKFILL_KIND != history.TAIL_KIND
