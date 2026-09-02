import yaml

from bot.spine import events
from lib.paths import PACKAGE_ROOT

MANIFEST = yaml.safe_load((PACKAGE_ROOT / "slack.manifest.yaml").read_text())
SUBSCRIBED = MANIFEST["settings"]["event_subscriptions"]["bot_events"]


def test_every_registered_handler_has_a_subscription():
    missing = [name for name in events.subscriptions() if name not in SUBSCRIBED]
    assert not missing, (
        f"spine registers {', '.join(missing)} but the manifest does not subscribe, "
        "so Slack will never deliver them"
    )


def test_nothing_is_subscribed_that_no_handler_lands():
    spare = [name for name in SUBSCRIBED if name not in events.subscriptions()]
    assert not spare, f"the manifest subscribes to {', '.join(spare)} with no handler to land it"


def test_the_message_family_is_subscribed_by_its_channel_name():
    assert "message" not in SUBSCRIBED, "message is not a subscribable bot event on its own"
    assert "message.channels" in SUBSCRIBED


def test_every_subscription_has_a_scope_that_can_deliver_it():
    scopes = set(MANIFEST["oauth_config"]["scopes"]["bot"])
    needs = {
        "message.channels": "channels:history",
        "reaction_added": "reactions:read",
        "reaction_removed": "reactions:read",
        "member_joined_channel": "channels:read",
        "member_left_channel": "channels:read",
        "team_join": "users:read",
        "channel_created": "channels:read",
        "channel_archive": "channels:read",
        "channel_unarchive": "channels:read",
        "channel_rename": "channels:read",
    }
    for name in SUBSCRIBED:
        assert needs[name] in scopes, f"{name} needs {needs[name]}, which the manifest does not ask for"
