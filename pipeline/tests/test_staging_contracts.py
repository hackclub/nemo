import yaml

from lib.paths import MIGRATIONS_DIR, WAREHOUSE_DIR

SCHEMA = WAREHOUSE_DIR / "models" / "staging" / "schema.yml"
CONTRACTED = ("fct_message", "fct_member_message", "fct_message_first_post")


def models():
    return {m["name"]: m for m in yaml.safe_load(SCHEMA.read_text())["models"]}


def shape(model):
    return [(c["name"], c.get("data_type")) for c in model.get("columns", [])]


def test_the_archive_derived_models_are_contracted():
    found = models()
    for name in CONTRACTED:
        enforced = found[name].get("config", {}).get("contract", {}).get("enforced")
        assert enforced is True, f"{name} has no enforced contract"


def test_every_contracted_column_declares_a_type():
    found = models()
    for name in CONTRACTED:
        missing = [col for col, kind in shape(found[name]) if kind is None]
        assert missing == [], f"{name} leaves {missing} untyped"


def test_member_message_matches_the_model_it_selects_star_from():
    found = models()
    assert shape(found["fct_member_message"]) == shape(found["fct_message"])


def test_first_post_declares_exactly_what_its_sql_selects():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_message_first_post.sql").read_text()
    declared = [col for col, _ in shape(models()["fct_message_first_post"])]
    assert declared == ["user_id", "channel_id", "ts", "posted_at"]
    for col in declared:
        assert col in sql


def test_member_message_really_is_a_select_star():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_member_message.sql").read_text()
    assert "select *" in sql.lower()


def test_first_post_merges_the_archive_with_search_rather_than_replacing_it():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_first_post.sql").read_text()
    assert "fct_message_first_post" in sql
    assert "fct_member_history" in sql
    assert "full outer join" in sql
    assert "least(" in sql


def test_first_post_can_never_move_a_date_later():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_first_post.sql").read_text()
    assert "greatest(" not in sql
    assert sql.count("least(") == 1


def test_every_mart_downstream_of_first_post_declares_a_version():
    import re

    marts = ("mart_channel_onboarding_scorecard", "mart_fast_reply_vs_retention",
             "mart_cohort_retention", "mart_cohort_survival")
    for name in marts:
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert re.search(r"'v\d+' as metric_version", sql), f"{name} has no metric_version"


def test_no_mart_reads_first_post_from_the_search_crawl():
    offenders = [p.name for p in (WAREHOUSE_DIR / "models" / "marts").glob("*.sql")
                 if "first_post_ts" in p.read_text() or "first_post_channel" in p.read_text()]
    assert offenders == [], "first post comes from fct_first_post, which takes the earlier source"


def test_the_cohort_marts_anchor_on_the_merged_first_post():
    for name in ("mart_monthly_cohorts", "mart_newcomer_channels"):
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert "ref('fct_first_post')" in sql, f"{name} no longer anchors on the merged first post"


def test_the_day_grain_model_is_archive_native():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_member_day.sql").read_text()
    assert "fct_member_message" in sql, "the day grain has to come from the archive"
    assert "fct_first_post" in sql, "a day offset needs the merged first post"
    assert "fct_member_activity" not in sql, "that is Slack's snapshot, not the archive"
    assert "dim_member" not in sql, "author_kind already excludes bots; dim_member is empty in dev"


def test_retention_is_measured_from_the_archive_not_slacks_snapshot():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_member_retention.sql").read_text()
    assert "fct_member_day" in sql, "retention reads posting days from the archive"
    assert "fct_member_activity" not in sql, (
        "the member-day snapshot starts part way through the history and has gaps, "
        "which blanked whole cohorts behind the coverage floor"
    )


def test_the_serving_view_does_not_copy_the_day_grain():
    sql = (WAREHOUSE_DIR / "models" / "marts" / "mart_member_day.sql").read_text()
    assert "materialized='view'" in sql, "a second copy of 3M rows earns nothing"
    assert "fct_member_day" in sql


def test_survival_marks_the_days_it_cannot_see_rather_than_calling_them_zero():
    sql = (WAREHOUSE_DIR / "models" / "marts" / "mart_cohort_survival.sql").read_text()
    assert "as observable" in sql, "a cohort that has not aged must say so, not read zero"
    assert "newest_first_post" in sql, (
        "a day is observable only once every member of the cohort has lived through it"
    )
    assert "observed_through" in sql


def test_no_mart_reaches_around_the_staging_layer():
    marts = (WAREHOUSE_DIR / "models" / "marts").glob("*.sql")
    offenders = [p.name for p in marts if "source(" in p.read_text()]
    assert offenders == []


def test_member_channel_is_built_from_the_archive_not_search():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_member_channel.sql").read_text()
    assert "fct_member_message" in sql
    assert "member_channel_message" not in sql
    assert "source(" not in sql


def test_member_channel_still_gives_the_mart_every_column_it_reads():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_member_channel.sql").read_text()
    mart = (WAREHOUSE_DIR / "models" / "marts" / "mart_newcomer_channels.sql").read_text()
    for col in ("user_id", "channel_id", "messages", "returned"):
        assert col in sql, f"fct_member_channel lost {col}"
        assert f"f.{col}" in mart or "c.user_id = f.user_id" in mart


def test_member_channel_messages_stays_integer_so_the_mart_contract_holds():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_member_channel.sql").read_text()
    assert "count(*)::integer as messages" in sql


def test_every_contracted_mart_column_summed_from_staging_is_typed_consistently():
    import re

    import yaml

    marts = yaml.safe_load((WAREHOUSE_DIR / "models" / "marts" / "schema.yml").read_text())
    contracted = {m["name"]: m for m in marts["models"]
                  if m.get("config", {}).get("contract", {}).get("enforced")}
    assert "mart_newcomer_channels" in contracted

    declared = {c["name"]: c.get("data_type")
                for c in contracted["mart_newcomer_channels"]["columns"]}
    assert declared["newcomer_messages"] == "bigint"

    mart = (WAREHOUSE_DIR / "models" / "marts" / "mart_newcomer_channels.sql").read_text()
    summed = re.search(r"sum\(f\.messages\)", mart)
    assert summed, "the mart no longer sums f.messages; recheck the declared type"


def test_the_expensive_response_model_is_materialized_not_recomputed_per_test():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_first_response.sql").read_text()
    assert "materialized='table'" in sql or "materialized='incremental'" in sql, (
        "fct_first_response joins fct_message twice over 50M rows and has 6 tests; "
        "as a view each test recomputes the whole chain"
    )


def test_the_response_model_is_indexed_on_the_key_its_tests_check():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_first_response.sql").read_text()
    assert "'columns': ['newcomer_id']" in sql
    assert "'unique': True" in sql


def test_the_four_marts_read_lifetime_messages_not_the_slack_window():
    marts = ("mart_participation_concentration", "mart_activity_distribution",
             "mart_onboarding_recurrence_funnel", "mart_monthly_cohorts")
    for name in marts:
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert "fct_member_lifetime_messages" in sql, f"{name} still on the Slack window"
        assert "channel_messages_posted" not in sql, f"{name} still reads the windowed count"


def test_lifetime_messages_comes_from_the_archive():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_member_lifetime_messages.sql").read_text()
    assert "fct_member_month_messages" in sql
    assert "fct_member_window" not in sql
    assert "::integer" in sql


def test_every_repointed_mart_bumped_its_version():
    want = {"mart_participation_concentration": "v5", "mart_activity_distribution": "v18",
            "mart_onboarding_recurrence_funnel": "v17", "mart_monthly_cohorts": "v4",
            "mart_newcomer_channels": "v5"}
    for name, version in want.items():
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert f"'{version}' as metric_version" in sql, f"{name} is not at {version}"


def test_top_posters_carries_no_name_because_cachet_resolves_it():
    sql = (WAREHOUSE_DIR / "models" / "marts" / "mart_top_posters.sql").read_text()
    assert "display_name" not in sql
    assert "fct_member_month_messages" in sql
    assert "fct_top_posters" not in sql


def test_no_mart_reads_the_search_based_reply_or_poster_sources():
    for name in ("mart_fast_reply_vs_retention", "mart_channel_onboarding_scorecard",
                 "mart_response_rate"):
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert "fct_first_response" in sql, f"{name} not cut over"
        assert "fct_first_reply" not in sql, f"{name} still on the search crawl"
        assert "fct_member_first_reply" not in sql, f"{name} still on the search crawl"


def test_the_cutover_marts_bumped_their_versions():
    want = {"mart_top_posters": "v4", "mart_fast_reply_vs_retention": "v11",
            "mart_channel_onboarding_scorecard": "v9", "mart_response_rate": "v3"}
    for name, version in want.items():
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert f"'{version}' as metric_version" in sql, f"{name} is not at {version}"


def test_the_response_rate_counts_newcomers_not_everyone_with_a_first_post():
    sql = (WAREHOUSE_DIR / "models" / "marts" / "mart_response_rate.sql").read_text()
    assert "cohort_at" in sql, (
        "the archive's first post is the oldest message it holds, so a member who lurked "
        "for years lands in whatever month they finally posted; gate on the join date"
    )
    for guard in ("is_bot", "is_deleted", "invite_pending"):
        assert guard in sql, f"mart_response_rate counts {guard} accounts as newcomers"


def test_the_response_model_exposes_when_the_bot_replied_not_just_whether():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_first_response.sql").read_text()
    assert "t.bot_at as bot_at" in sql, (
        "mart_response_rate splits bot_replied_first from bot_first_then_member, "
        "which needs the bot timestamp to compare against responded_at"
    )
    assert "on_schema_change='fail'" in sql, (
        "on the default 'ignore' a new column never reaches the table and on "
        "'append_new_columns' it arrives null for every row already built; either way "
        "bot_replied_first reads zero for all of history, so fail and force a full refresh"
    )


def test_the_spine_carries_the_indexes_the_response_model_joins_on():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_message.sql").read_text()
    assert "['channel_id', 'thread_root_ts']" in sql, (
        "fct_first_response joins fct_message on (channel_id, thread_root_ts); without the "
        "index that is a sequential scan over every message in the workspace, on every "
        "nightly run, and archive.message already carries the same index"
    )


def test_the_response_model_is_incremental_with_a_lookback():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_first_response.sql").read_text()
    assert "materialized='incremental'" in sql
    assert "unique_key='newcomer_id'" in sql
    assert "is_incremental()" in sql
    assert "lookback_hours" in sql, (
        "an unanswered first post can become answered later, so the window must reach back"
    )


def test_the_message_spine_is_a_relation_not_a_view_over_the_archive():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_message.sql").read_text()
    assert "materialized='incremental'" in sql, (
        "seven models read fct_message; as a view each one rescans the whole archive, "
        "and every run has to CREATE OR REPLACE it behind whichever reader is still open"
    )
    assert "unique_key=['channel_id', 'ts']" in sql
    assert "incremental_strategy='delete+insert'" in sql
    assert "is_incremental()" in sql
    assert "updated_at >" in sql, "the window must key off the archive's own change stamp"
    assert "lookback_hours" in sql


def test_nothing_writes_a_deletion_the_spine_would_have_to_sweep():
    from lib import archive

    assert not hasattr(archive, "mark_deleted")
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_message.sql").read_text()
    assert "deleted_at" not in sql, (
        "the archive records no deletion, so the spine carries neither a filter nor a sweep "
        "for one; both come back together if it ever does"
    )


def test_the_deletion_wrapper_is_still_refused_a_body():
    from lib import archive

    assert archive.body_of({"type": "message", "subtype": archive.GONE}) is None, (
        "body_of must keep returning None for a deletion envelope, or it falls through and "
        "the wrapper is recorded as if it were a message"
    )


def test_an_edit_wrapper_is_still_unwrapped():
    from lib import archive

    inner = {"ts": "1.1", "text": "after"}
    envelope = {"type": "message", "subtype": archive.CHANGED, "message": inner}
    assert archive.body_of(envelope) == inner


def test_the_archive_carries_the_index_the_incremental_leans_on():
    sql = (MIGRATIONS_DIR / "0095_archive_message_change_markers.sql").read_text()
    assert "archive.message (updated_at)" in sql


def test_the_spine_proves_uniqueness_with_its_index_not_a_54m_row_group_by():
    schema = (WAREHOUSE_DIR / "models" / "staging" / "schema.yml").read_text()
    assert "channel_id || '-' || ts" not in schema, (
        "the expression test cost 225.78s on fct_message and 191.22s on fct_member_message "
        "to re-prove what the unique index already guarantees"
    )
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_message.sql").read_text()
    assert "'unique': True" in sql, "something has to enforce it, and the index is the cheap half"




def test_the_dead_onboarding_funnel_is_dropped_rather_than_left_granted():
    sql = (MIGRATIONS_DIR / "0096_drop_onboarding_funnel.sql").read_text()
    assert "DROP TABLE IF EXISTS analytics.mart_onboarding_funnel" in sql
    models = {p.stem for p in (WAREHOUSE_DIR / "models").rglob("*.sql")}
    assert "mart_onboarding_funnel" not in models, "dropping a model dbt still builds would loop"


def test_the_bot_only_reply_is_its_own_class_not_silence():
    sql = (WAREHOUSE_DIR / "models" / "marts" / "mart_fast_reply_vs_retention.sql").read_text()
    assert "when not r.answered or r.bot_replied then 'none'" not in sql, (
        "that or also swallowed newcomers a member did answer, whenever a bot replied too"
    )
    assert "when r.bot_replied then 'bot'" in sql
    assert "'v11' as metric_version" in sql


def test_the_scorecard_counts_a_fast_member_reply_even_when_a_bot_also_replied():
    sql = (WAREHOUSE_DIR / "models" / "marts" / "mart_channel_onboarding_scorecard.sql").read_text()
    assert "and not bot_replied as fast_reply" not in sql
    assert "'v9' as metric_version" in sql


def test_the_band_ladder_is_declared_once_in_the_mart():
    sql = (WAREHOUSE_DIR / "models" / "marts" / "mart_channel_bands.sql").read_text()
    assert "band_top" in sql, "the mart has to publish the edge Rails used to hold"
    helper = (WAREHOUSE_DIR.parent / "web" / "app" / "helpers" / "home_helper.rb").read_text()
    assert "BAND_TOP" not in helper, "Rails declared dbt's ladder a third time"
    assert "b.band_top" in helper


def test_the_two_day_thirty_windows_no_longer_share_a_name():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_member_retention.sql").read_text()
    assert "posted_within_30d_of_joining" in sql, "one anchors on cohort_at, the other on first_post_on"
    assert "as posted_within_30d\n" not in sql


def test_retention_is_incremental_over_a_window_that_outlasts_day_ninety():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_member_retention.sql").read_text()
    assert "materialized='incremental'" in sql
    assert "settles_after_days = 90" in sql, (
        "day_90_covered flips up to 90 days after a first post, so a shorter window "
        "would freeze a stale false"
    )
    assert "not exists (select 1 from {{ this }}" in sql


def test_the_hot_staging_views_are_relations_so_their_tests_stop_re_deriving_them():
    for name in ("fct_first_post", "fct_message_first_post", "fct_member_channel"):
        sql = (WAREHOUSE_DIR / "models" / "staging" / f"{name}.sql").read_text()
        assert "materialized='table'" in sql, f"{name} is still re-derived once per test"


def test_the_four_spine_marts_read_the_rollup_not_the_spine():
    for name in ("mart_activity_clock", "mart_channel_clock",
                 "mart_archive_day_coverage", "mart_archive_channel_coverage"):
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert "fct_message_hour" in sql, f"{name} still aggregates the spine directly"
    for name in ("mart_activity_clock", "mart_channel_clock"):
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert "ref('fct_message')" not in sql, f"{name} still touches 54M rows for its window edge"


def test_the_rollup_and_the_month_model_carry_their_own_watermark():
    for name in ("fct_message_hour", "fct_member_month_messages"):
        sql = (WAREHOUSE_DIR / "models" / "staging" / f"{name}.sql").read_text()
        assert "materialized='incremental'" in sql
        assert "observed_through" in sql, f"{name} has no watermark to window on"
        assert "is_incremental()" in sql
