import logging
import os
import threading

from bot.core import loops, session
from bot.nemo import channel, channelguards, channels, chat, guards, guardwork

log = logging.getLogger("bot.nemo")

NAME = "nemo"
CASES = "fd_case_changed"
CHAT = "fd_chat_changed"
OUTBOX = "fd_outbox_waiting"
CONVERSATION = "fd_conversation_changed"
GUARD = "fd_thread_guard"
CHANNEL_GUARD = "fd_channel_guard"

DEFAULT_SECONDS = 300
DEFAULT_JOIN_SECONDS = 1800
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


def every_join_sweep():
    return int(os.environ.get("NEMO_JOIN_SECONDS", DEFAULT_JOIN_SECONDS))


def join_sweep(desk):
    channels.reconcile(desk.client)


def apart(*doing):
    for name, work in doing:
        try:
            work()
        except Exception:
            log.exception("nemo: %s failed", name)


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
        unshared = channel.waiting_files(conn)
        guards.refresh(conn)
        channelguards.refresh(conn)
        destroying = guards.pending(conn)
        lifting = guards.lifting(conn)

    posted = each(missing, "still has no card", channel.post_report, client, channel_id)
    drawn = each(standing, "could not be redrawn", channel.redraw, client, channel_id)
    carried = each(
        unmirrored, "has chat that did not go out", channel.mirror, client, channel_id
    )
    each(unshared, "has a file that never went into the thread",
         channel.carry_files, client, channel_id)
    each(following, "has a follow-up still waiting",
         channel.carry_follow_ups, client, channel_id)
    each(woke, "was reopened without saying so",
         channel.tell_the_wake, client, channel_id)
    desk.echo_queued()
    desk.tick_queued()

    for guard_id in destroying:
        apart((f"destroying guard {guard_id}", lambda id=guard_id: guardwork.run_destroy(client, id)))
    for guard_id in lifting:
        apart((f"lifting guard {guard_id}", lambda id=guard_id: guardwork.lift_lock(client, id)))
    apart(
        ("clearing what the guard could not remove", lambda: guardwork.sweep_removals(client)),
        ("resetting sessions the guard has earned", guardwork.sweep_strikes),
    )

    return posted, drawn, carried


def start(desk, stopping, channel_id=None):
    with session() as conn:
        log.info("nemo: watching %s guarded thread(s) and %s guarded channel(s)",
                 guards.refresh(conn), channelguards.refresh(conn))

    def heard(channel_name, told):
        if channel_name == CHAT:
            desk.mirror(told)
        elif channel_name == OUTBOX:
            apart(("echoing", desk.echo_queued), ("ticking", desk.tick_queued))
        elif channel_name == GUARD:
            with session() as conn:
                guards.refresh(conn)
            threading.Thread(
                target=guardwork.run_destroy, args=(desk.client, told),
                name=f"nemo-guard-{told}", daemon=True,
            ).start()
        elif channel_name == CHANNEL_GUARD:
            with session() as conn:
                channelguards.refresh(conn)
        elif channel_name == CONVERSATION:
            apart(("catching up", lambda: desk.caught_up(told)),
                  ("ticking", desk.tick_queued))
        else:
            desk.caught_up(told)

    return (
        loops.watching(NAME, (CASES, CHAT, OUTBOX, CONVERSATION, GUARD, CHANNEL_GUARD),
                       heard, stopping),
        loops.sweeping(NAME, every(), lambda: once(desk, channel_id), stopping),
        loops.sweeping(f"{NAME}-joins", every_join_sweep(), lambda: join_sweep(desk), stopping),
    )
