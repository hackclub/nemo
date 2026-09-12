import pytest

from seed.guards import SeedRefused, check_target_name, target_allowed


@pytest.mark.parametrize("dbname", ["mnemosyne_dev", "mnemosyne_test", "anything_seed"])
def test_the_allowed_suffixes_pass(dbname):
    assert target_allowed(dbname)


@pytest.mark.parametrize(
    "dbname",
    [
        "mnemosyne",
        "",
        "postgres",
        "mnemosyne_devious",
        "mnemosyne_dev_backup",
        "dev",
        "MNEMOSYNE_DEV",
    ],
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


def test_every_shape_check_resolves_against_the_captured_profile():
    import json

    from seed import verify
    from seed.profile import PROFILE_FILE

    profile = json.loads(PROFILE_FILE.read_text())
    paths = ([path for path, _, _ in verify.SHAPE_CHECKS]
             + [size for _, _, size in verify.SHAPE_CHECKS]
             + [path for path, _, _ in verify.QUANTILE_CHECKS])

    for path in sorted(set(paths)):
        try:
            verify.dig(profile, path)
        except KeyError:
            pytest.fail(
                f"verify.py checks {path!r} but profile.json has no such key, so "
                "`nemo seed` dies on a KeyError after the whole build has already run"
            )
