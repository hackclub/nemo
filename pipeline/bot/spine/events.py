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


def register(app):
    def land(event, body):
        events.land(body.get("event_id"), event)

    for name in MESSAGE_EVENTS + ACTIVITY_EVENTS:
        app.event(name)(land)

    log.info("spine: landing %d event type(s)", len(MESSAGE_EVENTS) + len(ACTIVITY_EVENTS))
