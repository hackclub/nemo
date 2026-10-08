import logging

from bot.core import privileged, session
from bot.nemo import channelguards, guard_actions

log = logging.getLogger("bot.nemo")

GIVE_UP_AFTER = 5
PER_DRAIN = 50


def rate_limited(failure):
    return getattr(failure, "http_status", None) == 429


def drain(client, settled=None):
    finished = 0
    limited = False
    with session() as conn:
        pending = channelguards.claim_removals(conn, PER_DRAIN)
        for event_id, channel_id, message_ts in pending:
            try:
                guard_actions.remove(client, channel_id, message_ts, max_retries=0)
            except Exception as failure:
                if rate_limited(failure):
                    limited = True
                    log.info("nemo: deletes are rate limited, leaving the rest for the next pass")
                    break
                if not privileged.gone(failure):
                    still = channelguards.removal_failed(conn, event_id, str(failure)[:500],
                                                         GIVE_UP_AFTER)
                    if not still:
                        finished += 1
                        log.warning("nemo: gave up deleting %s in %s after %s attempts: %s",
                                    message_ts, channel_id, GIVE_UP_AFTER, failure)
                    continue
            channelguards.removed(conn, event_id)
            finished += 1

    if finished:
        log.info("nemo: settled %s queued allow-list delete(s)", finished)
        if settled is not None:
            settled()
    return len(pending) == PER_DRAIN and not limited
