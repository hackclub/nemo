import logging

from bot.core import privileged
from bot.nemo import memberguards

log = logging.getLogger("bot.nemo")

KIND = memberguards.DEACTIVATION

DEACTIVATED = privileged.DEACTIVATED
REACTIVATED = privileged.REACTIVATED

FAILED = "failed"

DRY_RUN_OUTCOMES = ("off", "would")


def is_success(outcome, expected):
    return outcome == expected or outcome in DRY_RUN_OUTCOMES


def enforce(client, conn, guard):
    outcome = privileged.deactivate(guard["subject_id"], conn)
    if not is_success(outcome, DEACTIVATED):
        memberguards.mark_failed(conn, guard["id"], outcome)
        memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], None,
                              FAILED, detail=outcome)
        log.warning("nemo: deactivation %s could not take %s down: %s",
                    guard["id"], guard["subject_id"], outcome)
        return False

    memberguards.mark_enforced(conn, guard["id"], dry_run=outcome in DRY_RUN_OUTCOMES)
    memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], None,
                          DEACTIVATED, detail=outcome)
    log.warning("nemo: deactivation %s is now held on %s (%s)",
                guard["id"], guard["subject_id"], outcome)
    return True


def lift(client, conn, guard, notify_member=True):
    outcome = privileged.reactivate(guard["subject_id"], conn)
    if not is_success(outcome, REACTIVATED):
        memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], None,
                              FAILED, detail=outcome)
        log.warning("nemo: deactivation %s could not put %s back: %s",
                    guard["id"], guard["subject_id"], outcome)
        return False

    if memberguards.lift_done(conn, guard["id"]):
        memberguards.record_enforcement(conn, guard["id"], guard["subject_id"], None,
                              REACTIVATED, detail=outcome)
        log.warning("nemo: deactivation %s put %s back (%s)",
                    guard["id"], guard["subject_id"], outcome)
    return True
