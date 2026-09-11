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
             "mart_cohort_retention")
    for name in marts:
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert re.search(r"'v\d+' as metric_version", sql), f"{name} has no metric_version"


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
    want = {"mart_participation_concentration": "v5", "mart_activity_distribution": "v17",
            "mart_onboarding_recurrence_funnel": "v17", "mart_monthly_cohorts": "v3"}
    for name, version in want.items():
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert f"'{version}' as metric_version" in sql, f"{name} is not at {version}"


def test_top_posters_carries_no_name_because_cachet_resolves_it():
    sql = (WAREHOUSE_DIR / "models" / "marts" / "mart_top_posters.sql").read_text()
    assert "display_name" not in sql
    assert "fct_member_month_messages" in sql
    assert "fct_top_posters" not in sql


def test_no_mart_reads_the_search_based_reply_or_poster_sources():
    for name in ("mart_fast_reply_vs_retention", "mart_channel_onboarding_scorecard"):
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert "fct_first_response" in sql, f"{name} not cut over"
        assert "fct_first_reply" not in sql, f"{name} still on the search crawl"


def test_the_cutover_marts_bumped_their_versions():
    want = {"mart_top_posters": "v4", "mart_fast_reply_vs_retention": "v10",
            "mart_channel_onboarding_scorecard": "v8"}
    for name, version in want.items():
        sql = (WAREHOUSE_DIR / "models" / "marts" / f"{name}.sql").read_text()
        assert f"'{version}' as metric_version" in sql, f"{name} is not at {version}"


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


def test_the_message_spine_sweeps_rows_the_archive_has_tombstoned():
    sql = (WAREHOUSE_DIR / "models" / "staging" / "fct_message.sql").read_text()
    assert "deleted_at is not null" in sql, (
        "a deleted message never enters the incremental batch, so it has to be swept out "
        "of the table it was already written to"
    )


def test_the_archive_carries_the_indexes_the_incremental_leans_on():
    sql = (MIGRATIONS_DIR / "0095_archive_message_change_markers.sql").read_text()
    assert "archive.message (updated_at)" in sql
    assert "WHERE deleted_at IS NOT NULL" in sql
