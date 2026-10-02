import logging
import os

from bot.core import loops, outbox, session

log = logging.getLogger("bot.shroud")

NAME = "shroud"
OUTBOX = "fd_outbox_waiting"
DEFAULT_SECONDS = 300


def every():
    return int(os.environ.get("SHROUD_SWEEP_SECONDS", DEFAULT_SECONDS))


def once(carrier):
    with session() as conn:
        queued = outbox.any_waiting(conn)

    return sum(carrier.deliver(conversation_id) for conversation_id in queued)


def start(carrier, stopping):
    def heard(_channel_name, told):
        carrier.deliver(told)

    return (
        loops.watching(NAME, (OUTBOX,), heard, stopping),
        loops.sweeping(NAME, every(), lambda: once(carrier), stopping),
    )
