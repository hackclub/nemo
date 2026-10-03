import logging
import os

from bot.core import loops, outbox, session

log = logging.getLogger("bot.relay")

NAME = "relay"
OUTBOX = "fd_outbox_waiting"
DEFAULT_SECONDS = 300


def every():
    return int(os.environ.get("RELAY_SWEEP_SECONDS", DEFAULT_SECONDS))


def once(carrier):
    with session() as conn:
        queued = outbox.any_waiting(conn)

    return sum(carrier.deliver(conversation_id) for conversation_id in queued)


def start(carrier, stopping):
    def on_notify(_channel_name, payload):
        carrier.deliver(payload)

    return (
        loops.watching(NAME, (OUTBOX,), on_notify, stopping),
        loops.sweeping(NAME, every(), lambda: once(carrier), stopping),
    )
