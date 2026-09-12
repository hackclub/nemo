import pytest

from jobs import nightly_sync
from lib import sources


def test_every_source_declares_its_behaviour():
    for key in sources.KEYS:
        said = sources.source(key)
        missing = [field for field in sources.DECLARED if field not in said]
        assert not missing, f"{key} declares no {', '.join(missing)}"


def test_declared_values_come_from_the_allowed_sets():
    for key in sources.KEYS:
        said = sources.source(key)
        assert said["cadence"] in sources.CADENCES, key
        assert said["guard"] in sources.GUARDS, key
        assert said["resume"] in sources.RESUMES, key
        assert said["retention"] in sources.RETENTIONS, key


def test_nothing_is_pruned_unless_a_window_is_asked_for():
    for key in sources.KEYS:
        assert sources.source(key)["retention"] != "prune", key


def test_a_prune_floor_only_belongs_to_a_source_that_keeps_rows():
    for key in sources.KEYS:
        if sources.prune_floor(key):
            assert sources.source(key)["retention"] == "keep", key


def test_key_for_run_maps_legacy_and_suffixed_run_names_back_to_a_source():
    assert sources.key_for_run("channel_roster") == "channel_roster"
    assert sources.key_for_run("autojoin") == "channel_roster"
    assert sources.key_for_run("channel_info_names") == "channel_names"
    assert sources.key_for_run("admin_analytics_api:member") == "member_days"
    assert sources.key_for_run("admin_analytics_api:public_channel") == "channel_days"
    assert sources.key_for_run("admin_analytics_channel_month") == "channel_month"
    assert sources.key_for_run("nightly_sync") == "nightly_sync"


def test_parser_version_defaults_to_one():
    assert sources.parser_version("member_days") == 1
    assert sources.parser_version("not_a_source") == 1


STANDALONE_SOURCES = {
    "member_history",
    "channel_history",
    "channel_replies",
    "event_projector",
}


def test_the_nightly_runs_exactly_what_the_file_declares():
    ran = {name for name, _ in nightly_sync.stages()}
    assert ran <= set(sources.KEYS), "a stage must be a declared source"
    assert set(sources.KEYS) - ran == STANDALONE_SOURCES, (
        "a declared source missing from the nightly must be accounted for in STANDALONE_SOURCES, "
        "its own always-on worker rather than a nightly stage"
    )


def test_limits_are_ordered_and_hold_their_default():
    for key in sources.KEYS:
        for name, bounds in (sources.source(key).get("limits") or {}).items():
            assert bounds["min"] <= bounds["default"] <= bounds["max"], f"{key}.{name}"


def test_clamped_holds_a_value_inside_its_bounds():
    assert sources.clamped("channel_membership", "batch", 5) == 50
    assert sources.clamped("channel_membership", "batch", 9000) == 2000
    assert sources.clamped("channel_membership", "batch", 750) == 750
    assert sources.clamped("channel_membership", "batch", None) == 600


def test_an_unknown_source_is_refused_rather_than_empty():
    with pytest.raises(sources.Unknown):
        sources.source("teleporter")
    with pytest.raises(sources.Unknown):
        sources.limit("team_stats", "batch")


def test_a_source_claiming_num_found_actually_enforces_a_floor():
    import re

    from lib import sources
    from lib.paths import PACKAGE_ROOT

    claimed = {key for key in sources.KEYS if sources.SOURCES[key].get("guard") == "num_found"}
    pulls = "\n".join(p.read_text() for p in (PACKAGE_ROOT / "ingest").glob("*.py"))
    unfloored = set(re.findall(r"(\w+_SHORT_AT)\s*=\s*NO_FLOOR", pulls))
    assert "MEMBER_SHORT_AT" in unfloored
    assert "member_days" not in claimed


def test_member_days_says_it_has_no_usable_count():
    from lib import sources

    assert sources.says("member_days", "guard") == "none"


def test_every_declared_guard_is_in_the_vocabulary():
    from lib import sources

    for key in sources.KEYS:
        assert sources.SOURCES[key]["guard"] in sources.GUARDS


def test_the_dbt_error_class_list_matches_the_declared_fault_vocabulary():
    import re

    import yaml

    from lib.paths import DB_DIR, WAREHOUSE_DIR

    declared = set(yaml.safe_load((DB_DIR / "faults.yml").read_text())["classes"])
    schema = (WAREHOUSE_DIR / "models" / "staging" / "schema.yml").read_text()
    listed = re.search(r"error_class.*?values: \[(.*?)\]", schema, re.S)
    assert listed, "the error_class accepted_values block moved"
    accepted = {name.strip() for name in listed.group(1).split(",")}
    assert accepted == declared, (
        f"dbt accepts {sorted(accepted)} but db/faults.yml declares {sorted(declared)}"
    )


BUILDS_THE_WHOLE_WAREHOUSE = {"dbt"}


def warehouse_models():
    import re

    from lib.paths import WAREHOUSE_DIR

    models = {}
    for path in (WAREHOUSE_DIR / "models").rglob("*.sql"):
        if "target" in path.parts:
            continue
        body = path.read_text()
        models[path.stem] = (
            {tuple(pair) for pair in re.findall(r"source\(\s*'([^']+)'\s*,\s*'([^']+)'\s*\)", body)},
            set(re.findall(r"ref\(\s*'([^']+)'\s*\)", body)),
        )
    return models


def reached_from(models, tables):
    reached = {name for name, (read, _) in models.items() if read & tables}
    growing = True
    while growing:
        growing = False
        for name, (_, refs) in models.items():
            if name not in reached and refs & reached:
                reached.add(name)
                growing = True
    return reached


def test_every_feeds_entry_names_a_model_the_source_actually_reaches():
    models = warehouse_models()
    for key in sources.KEYS:
        if key in BUILDS_THE_WHOLE_WAREHOUSE:
            continue
        said = sources.source(key)
        tables = {tuple(w.split(".", 1)) for w in said["writes"] if "." in w}
        reached = reached_from(models, tables)
        for fed in said["feeds"]:
            assert fed in models, f"{key} says it feeds {fed}, which is not a warehouse model"
            assert fed in reached, (
                f"{key} says it feeds {fed}, but nothing downstream of {sorted(tables)} reads it"
            )


def test_the_warehouse_build_is_the_only_source_without_a_model_list():
    for key in BUILDS_THE_WHOLE_WAREHOUSE:
        assert sources.source(key)["writes"] == ["analytics"], key
