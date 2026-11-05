import logging

from bot.core import session
from bot.core.formatting import short_end
from bot.nemo import channel, channels, memberguards
from bot.nemo.enforcement import ENFORCEMENTS

log = logging.getLogger("bot.nemo")

EXPIRED_REASON = "End date reached"
ALREADY_DEACTIVATED = "Already deactivated"

NEXT_EXPIRY = """
SELECT extract(epoch FROM least(
    (SELECT min(expires_at) FROM fd.member_guards
      WHERE state = 'live' AND expires_at IS NOT NULL),
    (SELECT min(starts_at) FROM fd.member_guards WHERE state = 'scheduled'),
    (SELECT min(expires_at) FROM fd.thread_guards
      WHERE kind = 'lock' AND state IN ('warned', 'running') AND expires_at IS NOT NULL),
    (SELECT min(expires_at) FROM fd.channel_guards
      WHERE state = 'live' AND expires_at IS NOT NULL)
) - now())
"""

DEFAULT_ENDING_HOURS = 36
MAX_ENDING_HOURS = 720


def ending_window(conn):
    raw = channels.setting(conn, channels.SWEEP_SOON_HOURS)
    try:
        hours = int(raw)
    except ValueError:
        hours = 0
    if not 1 <= hours <= MAX_ENDING_HOURS:
        hours = DEFAULT_ENDING_HOURS
    return f"{hours} hours"


def notifies_member(conn):
    return channels.setting(conn, channels.SWEEP_TELLS_MEMBER) != "off"

HEADING = "*Ending soon*"
LINE = "• <@{who}> {what}{where} until {when}{case}"


def enforcement_for(guard):
    return ENFORCEMENTS.get(guard["kind"])


def release(client, conn, guard):
    enforcement = enforcement_for(guard)
    if enforcement is None:
        return True
    return enforcement.lift(client, conn, guard, notify_member=notifies_member(conn))


def release_now(client, guard):
    with session() as conn:
        return release(client, conn, guard)


def lapse(client, conn, guard):
    if not memberguards.lift(conn, guard["id"], memberguards.NEMO, EXPIRED_REASON,
                               kind=guard["kind"]):
        return False

    memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], guard["channel_id"],
                          "released", detail=EXPIRED_REASON)
    release(client, conn, guard)

    log.info("nemo: %s %s on %s has run out and is lifted",
             guard["kind"], guard["id"], guard["subject_id"])
    return True


def seconds_to_next_expiry(conn):
    row = conn.execute(NEXT_EXPIRY).fetchone()
    return float(row[0]) if row and row[0] is not None else None


def sweep_lapsed(client):
    with session() as conn:
        due = memberguards.lapsed(conn)

    for guard in due:
        with session() as conn:
            try:
                lapse(client, conn, guard)
            except Exception as failure:
                log.warning("nemo: could not lift %s: %s", guard["id"], failure)
    return len(due)


def start_scheduled(conn, guard):
    if guard["ended"]:
        return memberguards.cancel(conn, guard["id"], memberguards.NEMO, EXPIRED_REASON)
    if guard["overlapped"]:
        return memberguards.cancel(conn, guard["id"], memberguards.NEMO, ALREADY_DEACTIVATED)
    if not memberguards.start(conn, guard):
        return False

    log.info("nemo: scheduled %s %s on %s has started", guard["kind"], guard["id"], guard["subject_id"])
    return True


def sweep_scheduled():
    with session() as conn:
        due = memberguards.due(conn)

    for guard in due:
        with session() as conn:
            try:
                start_scheduled(conn, guard)
            except Exception as failure:
                log.warning("nemo: could not start %s: %s", guard["id"], failure)
    return len(due)


LIFT_LOOKBACK = "2 hours"


def release_lifted(client, guard):
    with session() as conn:
        if not memberguards.claim(conn, guard["id"]) or memberguards.has_release_event(conn, guard["id"]):
            return False
        memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], guard["channel_id"],
                                        memberguards.RELEASED, detail=memberguards.LIFTED_MANUALLY)
        try:
            release(client, conn, guard)
        except Exception as failure:
            log.warning("nemo: could not say that %s was lifted: %s", guard["id"], failure)
    return True


def sweep_lifted(client):
    with session() as conn:
        waiting = memberguards.lifted_not_notified(conn, LIFT_LOOKBACK)

    for guard in waiting:
        try:
            release_lifted(client, guard)
        except Exception as failure:
            log.warning("nemo: could not say that %s was lifted: %s", guard["id"], failure)
    return len(waiting)


def sweep_failed(client):
    with session() as conn:
        failed_guards = memberguards.failed_for_retry(conn)

    for guard in failed_guards:
        enforcement = enforcement_for(guard)
        if enforcement is None:
            continue
        with session() as conn:
            try:
                enforcement.enforce(client, conn, guard)
            except Exception as failure:
                log.warning("nemo: could not take %s back up: %s", guard["id"], failure)
    return len(failed_guards)


def ending_line(guard):
    where = f" in <#{guard['channel_id']}>" if guard.get("channel_id") else ""
    case = f" (case {guard['case_id']})" if guard.get("case_id") else " (no case)"
    return LINE.format(
        who=guard["subject_id"], what=guard["kind"].replace("_", " "), where=where,
        when=short_end(guard["expires_at"]), case=case,
    )


def post_expiry_notice(client, guards, channel_id):
    lines = [HEADING] + [ending_line(one) for one in guards]
    client.chat_postMessage(channel=channel_id, text="\n".join(lines), unfurl_links=False)


def sweep_ending(client):
    with session() as conn:
        ending = memberguards.ending_not_notified(conn, ending_window(conn))
        firehouse_channel_id = channel.firehouse_channel(conn)

    if not ending or not firehouse_channel_id:
        return 0

    post_expiry_notice(client, ending, firehouse_channel_id)
    with session() as conn:
        for guard in ending:
            memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], None,
                                  memberguards.NOTIFIED, detail=memberguards.ENDING)
    log.info("nemo: notified that %s guard(s) are ending soon", len(ending))
    return len(ending)
