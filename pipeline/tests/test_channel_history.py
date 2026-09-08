from ingest import channel_history_pull as history


def test_tail_walks_forward_from_the_lookback_and_backfill_walks_older_ward_exclusive():
    assert history.walk_params("C1") == {"channel": "C1"}
    assert history.walk_params("C1", oldest="1700000000.000100") == {"channel": "C1", "oldest": "1700000000.000100"}
    assert history.walk_params("C1", latest="1600000000.000000") == {
        "channel": "C1", "latest": "1600000000.000000", "inclusive": False,
    }


def test_the_backfill_goes_first_until_every_channel_is_walked():
    assert history.pass_order(1188) == ("backfill", "tail")
    assert history.pass_order(0) == ("tail", "backfill")
    assert history.pass_order(1188, channels=["C1"]) == ("backfill",)
    assert history.pass_order(0, channels=["C1"]) == ("backfill",)


def test_the_backfill_takes_the_whole_batch_until_every_channel_is_walked():
    assert history.backfill_share(200, left=1188) == 200
    assert history.backfill_share(200, left=0) == 50
    assert history.backfill_share(200, left=0, full=True) == 200
    assert history.backfill_share(2, left=0) == 1


def test_revisit_from_steps_back_one_lookback_and_never_below_zero():
    week = history.LOOKBACK_DAYS * 86400
    assert history.revisit_from("1700000000.000000") == f"{1700000000 - week:.6f}"
    assert history.revisit_from("10.000000") == "0.000000"
    assert history.revisit_from("not a ts") == "not a ts"


def test_revisit_from_reaches_back_less_once_events_are_landing():
    day = history.LIVE_LOOKBACK_DAYS * 86400
    assert history.LIVE_LOOKBACK_DAYS < history.LOOKBACK_DAYS
    assert history.revisit_from("1700000000.000000", history.LIVE_LOOKBACK_DAYS) == \
        f"{1700000000 - day:.6f}"


def test_enqueue_selects_name_both_kinds_and_only_unfinished_channels_for_backfill():
    assert "coalesce(w.history_complete, false) = false" in history.BACKFILL_SELECT
    assert "d.archived IS NOT TRUE" in history.TAIL_SELECT
    assert history.BACKFILL_KIND != history.TAIL_KIND


def test_an_archived_channel_is_walked_once_and_never_revisited():
    assert "d.archived IS NOT TRUE" not in history.BACKFILL_SELECT, \
        "the backfill has to reach archived channels, their history is still readable"
    assert "d.archived IS NOT TRUE" in history.TAIL_SELECT, \
        "an archived channel takes no new messages, so the tail must never re-read it"
    assert "coalesce(w.history_complete, false) = false" in history.BACKFILL_SELECT, \
        "once its walk has reached the start an archived channel drops out for good"


def test_the_backfill_takes_live_channels_before_archived_ones():
    assert "CASE WHEN d.archived THEN 2000 ELSE 0 END" in history.BACKFILL_SELECT
