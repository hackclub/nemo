import logging

from bot.core import session
from bot.nemo import channel, channels, memberguards
from bot.nemo.enforcement import ENFORCEMENTS

log = logging.getLogger("bot.nemo")

LAPSED_BECAUSE = "the date it ran until has passed"

SOON_HOURS = 36
SOONEST = 720


def expiring_soon(conn):
    raw = channels.setting(conn, channels.SWEEP_SOON_HOURS)
    try:
        hours = int(raw)
    except ValueError:
        hours = 0
    if not 1 <= hours <= SOONEST:
        hours = SOON_HOURS
    return f"{hours} hours"


def notifies_member(conn):
    return channels.setting(conn, channels.SWEEP_TELLS_MEMBER) != "off"

HEADING = "*Ending soon*"
LINE = "• <@{who}> — {what}{where}, until {when}{case}"


def enforcement_for(guard):
    return ENFORCEMENTS.get(guard["kind"])


def release(client, conn, guard):
    enforcement = enforcement_for(guard)
    if enforcement is None:
        return True
    return enforcement.lift(client, conn, guard, tell=notifies_member(conn))


def release_now(client, guard):
    with session() as conn:
        return release(client, conn, guard)


def lapse(client, conn, guard):
    if not memberguards.lift(conn, guard["id"], memberguards.NEMO, LAPSED_BECAUSE,
                               kind=guard["kind"]):
        return False

    memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], guard["channel_id"],
                          "released", detail=LAPSED_BECAUSE)
    release(client, conn, guard)

    log.info("nemo: %s %s on %s has run out and is lifted",
             guard["kind"], guard["id"], guard["subject_id"])
    return True


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


LIFT_LOOKBACK = "2 hours"


def sweep_lifted(client):
    with session() as conn:
        untold = memberguards.lifted_untold(conn, LIFT_LOOKBACK)

    for guard in untold:
        with session() as conn:
            try:
                memberguards.record_enforcement(conn, guard["id"], guard["subject_id"],
                                      guard["channel_id"], memberguards.RELEASED,
                                      detail=memberguards.LIFTED_BY_HAND)
                release(client, conn, guard)
            except Exception as failure:
                log.warning("nemo: could not say that %s was lifted: %s", guard["id"], failure)
    return len(untold)


def sweep_lifting(client):
    with session() as conn:
        waiting = memberguards.still_lifting(conn)

    for guard in waiting:
        with session() as conn:
            try:
                release(client, conn, guard)
            except Exception as failure:
                log.warning("nemo: could not finish lifting %s: %s", guard["id"], failure)
    return len(waiting)


def sweep_dropped(client):
    with session() as conn:
        again = memberguards.dropped_awhile(conn)

    for guard in again:
        enforcement = enforcement_for(guard)
        if enforcement is None:
            continue
        with session() as conn:
            try:
                enforcement.take_up(client, conn, guard)
            except Exception as failure:
                log.warning("nemo: could not take %s back up: %s", guard["id"], failure)
    return len(again)


def line_about(guard):
    where = f" in <#{guard['channel_id']}>" if guard.get("channel_id") else ""
    case = f" (case {guard['case_id']})" if guard.get("case_id") else ", on no case"
    return LINE.format(
        who=guard["subject_id"], what=guard["kind"].replace("_", " "), where=where,
        when=guard["expires_at"].strftime("%-d %b"), case=case,
    )


def post_expiry_notice(client, guards, room):
    lines = [HEADING] + [line_about(one) for one in guards]
    client.chat_postMessage(channel=room, text="\n".join(lines), unfurl_links=False)


def sweep_ending(client):
    with session() as conn:
        ending = memberguards.ending_untold(conn, expiring_soon(conn))
        room = channel.internal_log_channel(conn)

    if not ending or not room:
        return 0

    post_expiry_notice(client, ending, room)
    with session() as conn:
        for guard in ending:
            memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], None,
                                  "told", detail=memberguards.ENDING)
    log.info("nemo: notified that %s guard(s) are ending soon", len(ending))
    return len(ending)
