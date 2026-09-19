import logging
import os

from bot.core import loops, session
from bot.nemo import channel, chat

log = logging.getLogger("bot.nemo")

NAME = "nemo"
CASES = "fd_case_changed"
CHAT = "fd_chat_changed"
OUTBOX = "fd_outbox_waiting"
CONVERSATION = "fd_conversation_changed"

DEFAULT_SECONDS = 300
GIVE_UP_AFTER = 3

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
                log.warning("nemo: case %s %s: %s", case_id, doing, failure)
                if failing >= GIVE_UP_AFTER:
                    log.warning(
                        "nemo: giving up this sweep, %s is failing for %d case(s) in a row",
                        doing, failing,
                    )
                    break
    return done


def once(desk, channel_id=None):
    client = desk.client

    with session() as conn:
        missing = [row[0] for row in conn.execute(UNCARDED).fetchall()]
        standing = [row[0] for row in conn.execute(WORTH_REDRAWING).fetchall()]
        unmirrored = chat.waiting_anywhere(conn)
        following = channel.waiting_follow_ups(conn)
        woke = channel.untold_wakes(conn)

    posted = each(missing, "still has no card", channel.post_report, client, channel_id)
    drawn = each(standing, "could not be redrawn", channel.redraw, client, channel_id)
    carried = each(
        unmirrored, "has chat that did not go out", channel.mirror, client, channel_id
    )
    each(following, "has a follow-up still waiting",
         channel.carry_follow_ups, client, channel_id)
    each(woke, "was reopened without saying so",
         channel.tell_the_wake, client, channel_id)
    desk.echo_queued()
    desk.tick_queued()

    return posted, drawn, carried


def start(desk, stopping, channel_id=None):
    def heard(channel_name, told):
        if channel_name == CHAT:
            desk.mirror(told)
        elif channel_name == OUTBOX:
            desk.echo_queued()
            desk.tick_queued()
        elif channel_name == CONVERSATION:
            desk.caught_up(told)
            desk.tick_queued()
        else:
            desk.caught_up(told)

    return (
        loops.watching(NAME, (CASES, CHAT, OUTBOX, CONVERSATION), heard, stopping),
        loops.sweeping(NAME, every(), lambda: once(desk, channel_id), stopping),
    )
