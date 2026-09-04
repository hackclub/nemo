import logging
import os
import threading

from bot.engine import outbox, session
from bot.nemo import channel, chat

log = logging.getLogger("bot.nemo")

DEFAULT_SECONDS = 300

UNCARDED = """
SELECT r.case_id
FROM fd.case_reports r
JOIN fd.intake_conversations v ON v.report_id = r.id
WHERE r.forwarded_ts IS NULL AND v.handed_off_at IS NOT NULL
ORDER BY r.received_at
LIMIT 20
"""

WORTH_REDRAWING = """
SELECT r.case_id
FROM fd.case_reports r
JOIN fd.cases c ON c.id = r.case_id
WHERE r.forwarded_ts IS NOT NULL
  AND (c.resolved_at IS NULL OR c.resolved_at > now() - interval '2 days')
ORDER BY c.updated_at DESC
LIMIT 200
"""


def every():
    return int(os.environ.get("NEMO_SWEEP_SECONDS", DEFAULT_SECONDS))


GIVE_UP_AFTER = 3


def each(cases, doing, work, client, channel_id):
    done, failing = 0, 0
    for case_id in cases:
        with session() as conn:
            try:
                work(client, conn, case_id, channel_id)
                done += 1
                failing = 0
            except Exception as failure:
                failing += 1
                log.warning("bot: case %s %s: %s", case_id, doing, failure)
                if failing >= GIVE_UP_AFTER:
                    log.warning(
                        "bot: giving up this sweep, %s is failing for %d case(s) in a row",
                        doing, failing,
                    )
                    break
    return done


def once(relay, channel_id=None):
    client = relay.nemo_client

    with session() as conn:
        missing = [row[0] for row in conn.execute(UNCARDED).fetchall()]
        standing = [row[0] for row in conn.execute(WORTH_REDRAWING).fetchall()]
        unmirrored = chat.waiting_anywhere(conn)
        queued = outbox.any_waiting(conn)

    posted = drawn = carried = 0
    if client is not None:
        posted = each(missing, "still has no card", channel.post_report, client, channel_id)
        drawn = each(standing, "could not be redrawn", channel.redraw, client, channel_id)
        carried = each(
            unmirrored, "has chat that did not go out", channel.mirror, client, channel_id
        )

    handed = sum(relay.deliver(conversation_id) for conversation_id in queued)
    return posted, drawn, carried, handed


def start(relay, stopping, channel_id=None):
    seconds = every()

    def loop():
        log.info("bot: catching up on anything missed, then sweeping every %ss", seconds)
        while True:
            try:
                once(relay, channel_id)
            except Exception:
                log.exception("bot: the sweep failed, trying again next time")
            if stopping.wait(seconds):
                return

    thread = threading.Thread(target=loop, name="bot-sweep", daemon=True)
    thread.start()
    return thread
