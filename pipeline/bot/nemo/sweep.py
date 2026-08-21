import logging
import os
import threading

from bot.engine import session
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


def each(cases, doing, work, client, channel_id):
    done = 0
    for case_id in cases:
        with session() as conn:
            try:
                work(client, conn, case_id, channel_id)
                done += 1
            except Exception as failure:
                log.warning("nemo: case %s %s: %s", case_id, doing, failure)
                if done == 0:
                    log.warning("nemo: giving up this sweep, %s is failing for every case", doing)
                    break
    return done


def once(client, channel_id=None):
    with session() as conn:
        missing = [row[0] for row in conn.execute(UNCARDED).fetchall()]
        standing = [row[0] for row in conn.execute(WORTH_REDRAWING).fetchall()]

    with session() as conn:
        unmirrored = chat.waiting_anywhere(conn)

    posted = each(missing, "still has no card", channel.post_report, client, channel_id)
    drawn = each(standing, "could not be redrawn", channel.redraw, client, channel_id)
    carried = each(unmirrored, "has chat that did not go out", channel.mirror, client, channel_id)
    return posted, drawn, carried


def start(client, stopping, channel_id=None):
    seconds = every()

    def loop():
        log.info("nemo: sweeping the firehouse every %ss, in case a change was missed", seconds)
        while not stopping.wait(seconds):
            try:
                once(client, channel_id)
            except Exception:
                log.exception("nemo: the sweep failed, trying again next time")

    thread = threading.Thread(target=loop, name="nemo-sweep", daemon=True)
    thread.start()
    return thread
