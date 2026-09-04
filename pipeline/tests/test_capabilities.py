import yaml

from bot.engine import access
from lib import capabilities
from lib.paths import PANELS_FILE

SAID = capabilities.table()
PANELS = yaml.safe_load(PANELS_FILE.read_text())["panels"]


def test_the_catalogue_is_consistent():
    assert capabilities.objections(SAID) == []


def test_every_capability_declares_a_known_area():
    areas = set(SAID["areas"])
    for key, one in capabilities.capabilities(SAID).items():
        assert one["area"] in areas, f"{key} declares area {one['area']!r}"


def test_a_superadmin_role_lists_no_capabilities():
    for name, one in capabilities.roles(SAID).items():
        if one.get("everything"):
            assert not one.get("capabilities"), f"{name} both is superadmin and lists capabilities"


def test_every_role_baseline_names_real_capabilities():
    known = set(capabilities.capabilities(SAID))
    for role, key in capabilities.role_capability_rows(SAID):
        assert key in known, f"{role} holds {key}, which is not a capability"


def test_record_scopes_come_from_the_declared_set():
    allowed = set(SAID["record_scopes"])
    for key, one in capabilities.capabilities(SAID).items():
        scope = one.get("record_scope")
        assert scope is None or scope in allowed, f"{key} declares scope {scope!r}"


def test_nemo_carries_every_scope_the_catalogue_declares():
    for scope in SAID["record_scopes"]:
        assert scope in access.CARRIED, f"nemo does not weigh the {scope} scope"


def test_nemo_refuses_a_scope_it_cannot_weigh():
    allowed, refusal = access.in_scope({"label": "Do a thing", "record_scope": "assigned"})
    assert allowed is False
    assert "assigned" in refusal


def test_nemo_allows_an_unscoped_capability():
    assert access.in_scope({"label": "Do a thing", "record_scope": None}) == (True, None)


def test_every_panel_needs_a_real_capability_or_nothing():
    known = set(capabilities.capabilities(SAID))
    for name, one in PANELS.items():
        want = one.get("needs")
        assert want is None or want in known, f"panel {name} needs {want!r}, not a capability"


def test_the_locked_capabilities_are_fd_only_and_fixed():
    locked = [k for k, one in capabilities.capabilities(SAID).items() if one.get("locked")]
    assert locked == [
        "case.read", "case.open", "case.categorise", "case.note", "case.people",
        "case.thread", "case.chat", "case.reply", "case.act", "case.resolve",
        "case.reverse", "case.reopen", "member.note", "identity.read", "channel.share",
        "engine.manage", "access.grant", "app.flip",
    ], locked


def test_only_one_role_is_a_superadmin():
    supers = [n for n, one in capabilities.roles(SAID).items() if one.get("everything")]
    assert supers == ["community_manager"], supers
