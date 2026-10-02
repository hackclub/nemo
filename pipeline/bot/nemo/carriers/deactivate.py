import logging

from bot.core import privileged
from bot.nemo import memberguards

log = logging.getLogger("bot.nemo")

KIND = memberguards.DEACTIVATION

DEACTIVATED = privileged.DEACTIVATED
REACTIVATED = privileged.REACTIVATED

FAILED = "failed"


def carried(how, wanted):
    return how in (wanted, "off", "would")


def take_up(client, conn, guard):
    how = privileged.deactivate(guard["subject_id"])
    if not carried(how, DEACTIVATED):
        memberguards.dropped(conn, guard["id"], how)
        memberguards.happened(conn, guard["id"], guard["subject_id"], None,
                              FAILED, detail=how)
        log.warning("nemo: deactivation %s could not take %s down: %s",
                    guard["id"], guard["subject_id"], how)
        return False

    memberguards.holding(conn, guard["id"])
    memberguards.happened(conn, guard["id"], guard["subject_id"], None,
                          DEACTIVATED, detail=how)
    log.warning("nemo: deactivation %s is now held on %s (%s)",
                guard["id"], guard["subject_id"], how)
    return True


def let_go(client, conn, guard, tell=True):
    how = privileged.reactivate(guard["subject_id"])
    if not carried(how, REACTIVATED):
        memberguards.happened(conn, guard["id"], guard["subject_id"], None,
                              FAILED, detail=how)
        log.warning("nemo: deactivation %s could not put %s back: %s",
                    guard["id"], guard["subject_id"], how)
        return False

    if memberguards.lift_done(conn, guard["id"]):
        memberguards.happened(conn, guard["id"], guard["subject_id"], None,
                              REACTIVATED, detail=how)
        log.warning("nemo: deactivation %s put %s back (%s)",
                    guard["id"], guard["subject_id"], how)
    return True
