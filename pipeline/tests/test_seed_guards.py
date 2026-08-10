import pytest

from seed.guards import SeedRefused, check_target_name, target_allowed


@pytest.mark.parametrize("dbname", ["mnemosyne_dev", "mnemosyne_test", "anything_seed"])
def test_the_allowed_suffixes_pass(dbname):
    assert target_allowed(dbname)


@pytest.mark.parametrize(
    "dbname",
    ["mnemosyne", "", "postgres", "mnemosyne_devious", "mnemosyne_dev_backup", "dev", "MNEMOSYNE_DEV"],
)
def test_everything_else_is_refused(dbname):
    assert not target_allowed(dbname)


def test_an_exact_allow_override_passes():
    assert target_allowed("mnemosyne", allow="mnemosyne")


def test_the_override_has_to_match_exactly():
    assert not target_allowed("mnemosyne", allow="mnemosyne_dev")
    assert not target_allowed("mnemosyne_other", allow="mnemosyne")


def test_check_names_the_database_it_refused():
    with pytest.raises(SeedRefused, match="mnemosyne is not a seed target"):
        check_target_name("mnemosyne", allow="")
