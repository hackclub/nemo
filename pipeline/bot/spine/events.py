import logging

from bot.engine import events

log = logging.getLogger("bot.spine")

MESSAGE_EVENTS = ("message",)

ACTIVITY_EVENTS = (
    "reaction_added",
    "reaction_removed",
    "member_joined_channel",
    "member_left_channel",
    "team_join",
    "channel_created",
    "channel_archive",
    "channel_unarchive",
    "channel_rename",
)

SUBSCRIBED_AS = {"message": ("message.channels",)}


def subscriptions():
    wanted = []
    for name in MESSAGE_EVENTS + ACTIVITY_EVENTS:
        wanted.extend(SUBSCRIBED_AS.get(name, (name,)))
    return sorted(wanted)


def register(app):
    def land(event, body):
        event_id = body.get("event_id")
        if not events.land(event_id, event):
            log.warning("spine: %s did not land, it is on the spill file", event_id)

    for name in MESSAGE_EVENTS + ACTIVITY_EVENTS:
        app.event(name)(land)

    drained = events.drain()
    log.info(
        "spine: landing %d event type(s), %d spilled event(s) recovered",
        len(MESSAGE_EVENTS) + len(ACTIVITY_EVENTS),
        drained,
    )
