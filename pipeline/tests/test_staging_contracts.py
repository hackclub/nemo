import yaml

from lib.paths import WAREHOUSE_DIR

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
