import logging
import os
import threading

from bot.core import loops, session
from bot.nemo import automod, channel, channelguards, channels, chat, guards, guard_actions
from bot.nemo import enforcement, guard_notices, guard_removals, memberguards, case_queue
from bot.nemo import responses, screening
from bot.nemo.enforcement import purge, sweep

log = logging.getLogger("bot.nemo")

NAME = "nemo"
CASES = "fd_case_changed"
CHAT = "fd_chat_changed"
OUTBOX = "fd_outbox_waiting"
CONVERSATION = "fd_conversation_changed"
GUARD = "fd_thread_guard"
CHANNEL_GUARD = "fd_channel_guard"
MEMBER_GUARD = "fd_member_guard"
APP_SETTING = "fd_app_setting"
AUTOMOD_WORD = "fd_automod_word"
CHANNEL_PURGE = "fd_channel_purge"
BLOCKED_DOMAIN = "fd_blocked_domain"
GUARD_NOTICE = "fd_guard_notice"
GUARD_REMOVE = "fd_guard_remove"

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

CARDLESS = """
SELECT c.id
FROM fd.cases c
WHERE c.card_ts IS NULL
  AND c.opened_at > now() - interval '1 day'
  AND NOT EXISTS (SELECT 1 FROM fd.case_reports r WHERE r.case_id = c.id)
ORDER BY c.opened_at
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


def join_sweep(case_channel):
    channels.reconcile(case_channel.client)


def join_channel(client, channel_id):
    if channelguards.guarding(channel_id) is None:
        return False

    with session() as conn:
        if channels.mode(conn) == channels.OFF or channels.inside(conn, channel_id):
            return False
        return channels.join(client, conn, channel_id, verb="joined")


def take_up(client, guard):
    with session() as conn:
        enforcement.take_up(client, conn, guard)


def apart(*doing):
    for name, work in doing:
        try:
            work()
        except Exception:
            log.exception("nemo: %s failed", name)


def flush_pending(client):
    with session() as conn:
        memberguards.refresh(conn)
        taking_up = memberguards.unenforced(conn)
        finishing = memberguards.still_lifting(conn)

    for guard in taking_up:
        apart((f"taking up {guard['kind']} {guard['id']}",
               lambda one=guard: take_up(client, one)))
    for guard in finishing:
        apart((f"finishing the lift of {guard['kind']} {guard['id']}",
               lambda one=guard: sweep.release_now(client, one)))
    return len(taking_up) + len(finishing)


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


def once(case_channel, channel_id=None):
    client = case_channel.client

    with session() as conn:
        missing = [row[0] for row in conn.execute(UNCARDED).fetchall()]
        cardless = [row[0] for row in conn.execute(CARDLESS).fetchall()]
        standing = [row[0] for row in conn.execute(WORTH_REDRAWING).fetchall()]
        unmirrored = chat.waiting_anywhere(conn)
        following = channel.waiting_follow_ups(conn)
        woke = channel.unannounced_reopens(conn)
        unshared = channel.waiting_files(conn)
        guards.refresh(conn)
        channelguards.refresh(conn)
        memberguards.refresh(conn)
        automod.refresh(conn)
        responses.refresh(conn)
        screening.refresh(conn)
        taking_up = memberguards.unenforced(conn)
        channel.internal_log_channel(conn)
        channel.react_channels(conn)
        destroying = guards.pending(conn)
        lifting = guards.lifting(conn)
        purging = [row[0] for row in purge.waiting(conn)]

    posted = each(missing, "still has no card", channel.post_report, client, channel_id)
    posted += each(cardless, "was opened without a card", case_queue.card, client, channel_id)
    drawn = each(standing, "could not be redrawn", channel.refresh_card, client, channel_id)
    carried = each(
        unmirrored, "has chat that did not go out", channel.mirror, client, channel_id
    )
    each(unshared, "has a file that never went into the thread",
         channel.carry_files, client, channel_id)
    each(following, "has a follow-up still waiting",
         channel.carry_follow_ups, client, channel_id)
    each(woke, "was reopened without saying so",
         channel.post_reopen_notice, client, channel_id)
    case_channel.echo_queued()
    case_channel.tick_queued()

    for guard_id in destroying:
        apart((f"destroying guard {guard_id}", lambda id=guard_id: guard_actions.run_destroy(client, id)))
    for guard_id in lifting:
        apart((f"lifting guard {guard_id}", lambda id=guard_id: guard_actions.lift_lock(client, id)))
    for purge_id in purging:
        apart((f"purging {purge_id}", lambda id=purge_id: purge.run(client, id)))
    for guard in taking_up:
        apart((f"taking up {guard['kind']} {guard['id']}",
               lambda one=guard: take_up(client, one)))
    apart(
        ("clearing unremoved guard artifacts", lambda: guard_actions.sweep_removals(client)),
        ("resetting sessions the guard has earned", guard_actions.sweep_strikes),
        ("lifting what has run out", lambda: sweep.sweep_lapsed(client)),
        ("completing in-progress lifts", lambda: sweep.sweep_lifting(client)),
        ("notifying manually lifted guards", lambda: sweep.sweep_lifted(client)),
        ("reclaiming released work", lambda: sweep.sweep_dropped(client)),
        ("notifying expiring guards", lambda: sweep.sweep_ending(client)),
    )

    return posted, drawn, carried


def start(case_channel, stopping, channel_id=None):
    with session() as conn:
        log.info("nemo: watching %s guarded thread(s), %s guarded channel(s), "
                 "%s shushed member(s) and %s automod word(s)",
                 guards.refresh(conn), channelguards.refresh(conn),
                 memberguards.refresh(conn), automod.refresh(conn))
        responses.refresh(conn)
        screening.refresh(conn)

    wake_notices = loops.draining(f"{NAME}-notices",
                                  lambda: guard_notices.drain(case_channel.client), stopping)
    wake_removals = loops.draining(f"{NAME}-removals",
                                   lambda: guard_removals.drain(case_channel.client, wake_notices),
                                   stopping, settle=1.0, every=5.0)

    def on_notify(channel_name, payload):
        if channel_name == GUARD_NOTICE:
            wake_notices()
        elif channel_name == GUARD_REMOVE:
            wake_removals()
        elif channel_name == CHAT:
            case_channel.mirror(payload)
        elif channel_name == OUTBOX:
            apart(("echoing", case_channel.echo_queued), ("ticking", case_channel.tick_queued))
        elif channel_name == GUARD:
            with session() as conn:
                guards.refresh(conn)
            threading.Thread(
                target=guard_actions.run_destroy, args=(case_channel.client, payload),
                name=f"nemo-guard-{payload}", daemon=True,
            ).start()
        elif channel_name == APP_SETTING:
            with session() as conn:
                channel.internal_log_channel(conn)
                channel.react_channels(conn)
                responses.refresh(conn)
        elif channel_name == AUTOMOD_WORD:
            with session() as conn:
                automod.refresh(conn)
        elif channel_name == BLOCKED_DOMAIN:
            with session() as conn:
                screening.refresh(conn)
        elif channel_name == CHANNEL_PURGE:
            threading.Thread(
                target=purge.run, args=(case_channel.client, payload),
                name=f"nemo-purge-{payload}", daemon=True,
            ).start()
        elif channel_name == CHANNEL_GUARD:
            with session() as conn:
                channelguards.refresh(conn)
            threading.Thread(
                target=join_channel, args=(case_channel.client, payload),
                name=f"nemo-seat-{payload}", daemon=True,
            ).start()
        elif channel_name == MEMBER_GUARD:
            threading.Thread(
                target=flush_pending, args=(case_channel.client,),
                name=f"nemo-member-guard-{payload}", daemon=True,
            ).start()
        elif channel_name == CONVERSATION:
            apart(("catching up", lambda: case_channel.caught_up(payload)),
                  ("ticking", case_channel.tick_queued))
        else:
            case_channel.caught_up(payload)

    return (
        loops.watching(NAME,
                       (CASES, CHAT, OUTBOX, CONVERSATION, GUARD, CHANNEL_GUARD,
                        MEMBER_GUARD, APP_SETTING, AUTOMOD_WORD, CHANNEL_PURGE,
                        GUARD_NOTICE, GUARD_REMOVE, BLOCKED_DOMAIN),
                       on_notify, stopping),
        loops.sweeping(NAME, every(), lambda: once(case_channel, channel_id), stopping),
        loops.sweeping(f"{NAME}-joins", every_join_sweep(), lambda: join_sweep(case_channel), stopping),
    )
