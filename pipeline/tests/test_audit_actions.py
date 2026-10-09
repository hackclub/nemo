from checks import audit_actions as check
from ingest import audit_logs_pull as pull
from lib import audit_actions


def test_every_action_names_a_known_category():
    held = audit_actions.catalogue()
    names = set(audit_actions.categories(held))
    for action, one in held["actions"].items():
        assert one["category"] in names, action
        assert one["label"] and one["sentence"], action


def test_every_category_holds_at_least_one_action():
    held = audit_actions.catalogue()
    used = {one["category"] for one in held["actions"].values()}
    assert used == set(audit_actions.categories(held))


def test_sentences_use_only_the_actor_and_the_entity():
    for action, one in audit_actions.catalogue()["actions"].items():
        stripped = one["sentence"]
        for placeholder in audit_actions.PLACEHOLDERS:
            stripped = stripped.replace(placeholder, "")
        assert "{" not in stripped and "}" not in stripped, action


def test_copy_has_no_em_dashes():
    for action, one in audit_actions.catalogue()["actions"].items():
        assert "—" not in one["label"] + one["sentence"], action


def test_every_action_the_pull_asks_slack_for_is_catalogued():
    wanted = set(pull.LOGIN_ACTIONS) | set(pull.CHANNEL_MEMBERSHIP_ACTIONS) | set(pull.IDENTITY_ACTIONS)
    assert audit_actions.unknown(wanted) == []


def test_an_unknown_action_falls_back_to_its_own_name():
    found = audit_actions.entry("brand_new_thing")

    assert found == {"category": None, "label": "brand new thing", "sentence": "{actor}: brand new thing"}
    assert audit_actions.entry("user_login")["label"] == "Signed in"


def test_unknown_lists_each_missing_action_once():
    assert audit_actions.unknown(["user_login", "brand_new_thing", "brand_new_thing", None]) == ["brand_new_thing"]


class Conn:
    def __init__(self, actions):
        self.actions = actions

    def execute(self, _sql, _params=None):
        return self

    def fetchall(self):
        return [(one,) for one in self.actions]


def test_the_nightly_check_warns_with_the_missing_names():
    assertion, status, observed, _expected = check.catalogued(Conn(["user_login", "brand_new_thing"]))

    assert status == "warn"
    assert "brand_new_thing" in observed
    assert check.catalogued(Conn(["user_login"]))[1] == "pass"
