import logging
import os
import threading

from bot.core import loops, session
from bot.nemo import automod, channel, channelguards, channels, chat, guards, guard_actions
from bot.nemo import enforcement, guard_notices, guard_removals, memberguards, case_queue
from bot.nemo import (
    bot_kicks, categories, internal_log, join_requests, missed_reactions, public_log, responses, screening,
    usergroups,
)
from bot.nemo.enforcement import purge, slowmode, sweep

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
PURGE = "fd_purge"
BLOCKED_DOMAIN = "fd_blocked_domain"
GUARD_NOTICE = "fd_guard_notice"
GUARD_REMOVE = "fd_guard_remove"
JOIN_REQUEST = "fd_channel_join_request"
AUDIT_EVENT = "fd_audit_event"
AUTOMOD_MATCH = "fd_automod_match"
BOT_KICK = "fd_bot_kick"
CATEGORY = "fd_infraction_category"
FIRE_ENGINE_SOURCE = '"fire_engine"'
NEMO_SOURCE = '"nemo"'
LOG_SOURCES = (FIRE_ENGINE_SOURCE, NEMO_SOURCE)

DEFAULT_SWEEP_SECONDS = 300
DEFAULT_JOIN_SWEEP_SECONDS = 1800
GIVE_UP_AFTER = 3

CASES_WITHOUT_REPORT_CARD = """
SELECT r.case_id
FROM fd.case_reports r
JOIN fd.intake_conversations v ON v.report_id = r.id
WHERE r.forwarded_ts IS NULL AND v.handed_off_at IS NOT NULL
ORDER BY r.received_at
LIMIT 20
"""

CASES_WITHOUT_CARD = """
SELECT c.id
FROM fd.cases c
WHERE c.card_ts IS NULL AND c.source_app <> 'lyla'
  AND c.opened_at > now() - interval '1 day'
  AND NOT EXISTS (SELECT 1 FROM fd.case_reports r WHERE r.case_id = c.id)
ORDER BY c.opened_at
LIMIT 20
"""

RECENT_REPORT_CARDS = """
SELECT r.case_id
FROM fd.case_reports r
JOIN fd.cases c ON c.id = r.case_id
WHERE r.forwarded_ts IS NOT NULL
  AND (c.resolved_at IS NULL OR c.resolved_at > now() - interval '2 days')
ORDER BY c.updated_at DESC
LIMIT 200
"""


def sweep_interval_seconds():
    return int(os.environ.get("NEMO_SWEEP_SECONDS", DEFAULT_SWEEP_SECONDS))


def join_sweep_interval_seconds():
    return int(os.environ.get("NEMO_JOIN_SECONDS", DEFAULT_JOIN_SWEEP_SECONDS))


JOIN_SWEEP_LOCK = threading.Lock()
join_sweep_requested = threading.Event()


def join_sweep(case_channel, stopping=None):
    client = case_channel.client
    if not JOIN_SWEEP_LOCK.acquire(blocking=False):
        join_sweep_requested.set()
        return
    try:
        while True:
            join_sweep_requested.clear()
            run_each(("joining configured channels", lambda: channels.join_configured(client)),
                     ("joining channels", lambda: channels.reconcile(client, stopping=stopping)))
            if not join_sweep_requested.is_set() or (stopping is not None and stopping.is_set()):
                return
    finally:
        JOIN_SWEEP_LOCK.release()


def start_join_sweep(case_channel, stopping):
    threading.Thread(target=join_sweep, args=(case_channel, stopping), name="nemo-join-sweep",
                     daemon=True).start()


def join_configured(client):
    run_each(("joining configured channels", lambda: channels.join_configured(client)))


def start_configured_joins(client):
    threading.Thread(target=join_configured, args=(client,), name="nemo-configured-joins",
                     daemon=True).start()


def apply_missed_close_reactions(client):
    run_each(("applying missed close reactions", lambda: missed_reactions.apply_missed_close_reactions(client)))


def start_missed_reaction_pass(client):
    threading.Thread(target=apply_missed_close_reactions, args=(client,), name="nemo-missed-reactions",
                     daemon=True).start()


def join_channel(client, channel_id):
    if not channelguards.is_guarded(channel_id):
        return False

    with session() as conn:
        if channels.mode(conn) == channels.OFF or channels.is_inside(conn, channel_id):
            return False
        return channels.join(client, conn, channel_id, verb="joined")


def join_and_post_notices(client, channel_id):
    run_each((f"joining {channel_id}", lambda: join_channel(client, channel_id)),
             ("syncing slow mode notices", lambda: slowmode.sync_notices(client)))


def enforce_guard(client, guard):
    with session() as conn:
        enforcement.enforce(client, conn, guard)


def run_each(*tasks):
    for name, work in tasks:
        try:
            work()
        except Exception:
            log.exception("nemo: %s failed", name)


def start_purge(client, purge_id):
    threading.Thread(target=purge.run, args=(client, purge_id),
                     name=f"nemo-purge-{purge_id}", daemon=True).start()


def start_join_request(client, request_id):
    threading.Thread(target=join_requests.run, args=(client, int(request_id)),
                     name=f"nemo-join-request-{request_id}", daemon=True).start()


def lift_expired_locks(client):
    with session() as conn:
        due = guards.expired_locks(conn)
    for guard_id in due:
        run_each((f"lifting guard {guard_id}", lambda one=guard_id: guard_actions.lift_lock(client, one)))


def lift_lapsed_channel_guards():
    with session() as conn:
        lifted_guards = channelguards.lift_lapsed(conn)
        if lifted_guards:
            channelguards.refresh(conn)
    for guard_id, kind, channel_id, thread_ts in lifted_guards:
        log.info("nemo: %s guard %s on %s%s ended", kind, guard_id, channel_id,
                 f" thread {thread_ts}" if thread_ts else "")
    return len(lifted_guards)


def lift_expired(client):
    run_each(("lifting what has run out", lambda: sweep.sweep_lapsed(client)),
             ("lifting expired thread locks", lambda: lift_expired_locks(client)),
             ("lifting expired channel guards", lift_lapsed_channel_guards))
    with session() as conn:
        return sweep.seconds_to_next_expiry(conn)


def apply_pending_guards(client):
    with session() as conn:
        memberguards.refresh(conn)
        pending_guards = memberguards.unenforced(conn)
        lifting_guards = memberguards.still_lifting(conn)
        lifted_guards = memberguards.lifted_not_notified(conn, sweep.LIFT_LOOKBACK)

    for guard in pending_guards:
        run_each((f"taking up {guard['kind']} {guard['id']}",
                  lambda one=guard: enforce_guard(client, one)))
    for guard in lifting_guards:
        run_each((f"finishing the lift of {guard['kind']} {guard['id']}",
                  lambda one=guard: sweep.release_now(client, one)))
    for guard in lifted_guards:
        run_each((f"releasing the lifted {guard['kind']} {guard['id']}",
                  lambda one=guard: sweep.release_lifted(client, one)))


def run_for_cases(cases, description, work, client, channel_id):
    succeeded_count, failing = 0, 0
    for case_id in cases:
        with session() as conn:
            try:
                work(client, conn, case_id, channel_id)
                succeeded_count += 1
                failing = 0
            except Exception as failure:
                failing += 1
                log.warning("nemo: case %s %s: %s", case_id, description, failure)
                if failing >= GIVE_UP_AFTER:
                    log.warning(
                        "nemo: giving up this sweep, %s is failing for %d case(s) in a row",
                        description, failing,
                    )
                    break
    return succeeded_count


def sweep_once(case_channel, channel_id=None):
    client = case_channel.client

    with session() as conn:
        report_case_ids = [row[0] for row in conn.execute(CASES_WITHOUT_REPORT_CARD).fetchall()]
        cardless_case_ids = [row[0] for row in conn.execute(CASES_WITHOUT_CARD).fetchall()]
        redraw_ids = [row[0] for row in conn.execute(RECENT_REPORT_CARDS).fetchall()]
        unmirrored_case_ids = chat.waiting_anywhere(conn)
        follow_up_case_ids = channel.waiting_follow_ups(conn)
        reopen_prompt_case_ids = channel.reopen_prompts_pending(conn)
        file_case_ids = channel.waiting_files(conn)
        guards.refresh(conn)
        channelguards.refresh(conn)
        memberguards.refresh(conn)
        automod.refresh(conn)
        responses.refresh(conn)
        screening.refresh(conn)
        categories.refresh(conn)
        channel.refresh_channels(conn)
        destroy_guard_ids = guards.pending_destroys(conn)
        lock_guard_ids = guards.expired_locks(conn)
        purge_ids = [row[0] for row in purge.queued_purges(conn)]
        join_request_ids = join_requests.queued(conn)

    posted = run_for_cases(report_case_ids, "still has no card", channel.post_report, client, channel_id)
    posted += run_for_cases(cardless_case_ids, "was opened without a card", case_queue.post_missing_card, client, channel_id)
    redrawn_count = run_for_cases(redraw_ids, "could not be redrawn", channel.refresh_card, client, channel_id)
    mirrored_count = run_for_cases(
        unmirrored_case_ids, "has chat that did not go out", channel.mirror, client, channel_id
    )
    run_for_cases(file_case_ids, "has a file that never went into the thread",
                  channel.post_files, client, channel_id)
    run_for_cases(follow_up_case_ids, "has a follow-up still waiting",
                  channel.post_follow_ups, client, channel_id)
    run_for_cases(redraw_ids, "has links that would not unfurl",
                  channel.post_unfurls, client, channel_id)
    run_for_cases(reopen_prompt_case_ids, "has a reopen prompt still waiting",
                  channel.post_reopen_prompt, client, channel_id)
    case_channel.mirror_outbox_replies()
    case_channel.mark_outbox_results()
    case_channel.announce_fire_engine()

    for guard_id in destroy_guard_ids:
        run_each((f"destroying guard {guard_id}", lambda id=guard_id: guard_actions.run_destroy(client, id)))
    for guard_id in lock_guard_ids:
        run_each((f"lifting guard {guard_id}", lambda id=guard_id: guard_actions.lift_lock(client, id)))
    for purge_id in purge_ids:
        start_purge(client, purge_id)
    for request_id in join_request_ids:
        run_each((f"joining for request {request_id}",
                  lambda one=request_id: join_requests.run(client, one)))
    run_each(
        ("clearing unremoved guard artifacts", lambda: guard_actions.sweep_removals(client)),
        ("removing ended lock notices", lambda: guard_actions.remove_lock_warnings(client)),
        ("posting internal log lines", lambda: internal_log.drain(client)),
        ("posting public log lines", lambda: public_log.drain(client)),
        ("kicking bots taken off allow lists", lambda: bot_kicks.drain(client)),
        ("resetting sessions the guard has earned", guard_actions.sweep_strikes),
        ("lifting what has run out", lambda: sweep.sweep_lapsed(client)),
        ("lifting expired channel guards", lift_lapsed_channel_guards),
        ("syncing slow mode notices", lambda: slowmode.sync_notices(client)),
        ("notifying manually lifted guards", lambda: sweep.sweep_lifted(client)),
        ("reclaiming released work", lambda: sweep.sweep_failed(client)),
        ("notifying expiring guards", lambda: sweep.sweep_ending(client)),
    )

    return posted, redrawn_count, mirrored_count


def drain_logs(client):
    return internal_log.drain(client) + public_log.drain(client)


def start(case_channel, stopping, channel_id=None):
    with session() as conn:
        log.info("nemo: watching %s guarded thread(s), %s guarded channel(s), "
                 "%s shushed member(s) and %s automod word(s)",
                 guards.refresh(conn), channelguards.refresh(conn),
                 memberguards.refresh(conn), automod.refresh(conn))
        responses.refresh(conn)
        screening.refresh(conn)
        categories.refresh(conn)
        channel.refresh_channels(conn)
        interrupted_ids = purge.requeue_interrupted(conn)
    if interrupted_ids:
        log.info("nemo: %s purge(s) were cut off by a restart and go again: %s",
                 len(interrupted_ids), interrupted_ids)

    wake_notices = loops.run_on_wake(f"{NAME}-notices",
                                  lambda: guard_notices.drain(case_channel.client), stopping)
    wake_member_guards = loops.run_on_wake(f"{NAME}-member-guards",
                                        lambda: apply_pending_guards(case_channel.client), stopping)
    wake_removals = loops.run_on_wake(f"{NAME}-removals",
                                   lambda: guard_removals.drain(case_channel.client, wake_notices),
                                   stopping, debounce_seconds=1.0, interval_seconds=5.0)
    wake_lapses = loops.run_on_timer(f"{NAME}-lapses", lambda: lift_expired(case_channel.client), stopping)
    wake_log = loops.run_on_wake(f"{NAME}-log", lambda: drain_logs(case_channel.client), stopping)
    wake_kicks = loops.run_on_wake(f"{NAME}-kicks", lambda: bot_kicks.drain(case_channel.client), stopping)

    def on_notify(channel_name, payload):
        if channel_name == GUARD_NOTICE:
            wake_notices()
        elif channel_name == AUDIT_EVENT:
            if any(source in (payload or "") for source in LOG_SOURCES):
                wake_log()
        elif channel_name == AUTOMOD_MATCH:
            wake_log()
        elif channel_name == BOT_KICK:
            wake_kicks()
        elif channel_name == CATEGORY:
            with session() as conn:
                categories.refresh(conn)
        elif channel_name == GUARD_REMOVE:
            wake_removals()
        elif channel_name == CHAT:
            case_channel.mirror(payload)
        elif channel_name == OUTBOX:
            run_each(("echoing", case_channel.mirror_outbox_replies), ("ticking", case_channel.mark_outbox_results))
        elif channel_name == GUARD:
            with session() as conn:
                guards.refresh(conn)
            threading.Thread(
                target=guard_actions.after_guard_change, args=(case_channel.client, payload),
                name=f"nemo-guard-{payload}", daemon=True,
            ).start()
            wake_lapses()
        elif channel_name == APP_SETTING:
            with session() as conn:
                channel.refresh_channels(conn)
                responses.refresh(conn)
            if payload == channels.SETTING:
                start_join_sweep(case_channel, stopping)
            else:
                start_configured_joins(case_channel.client)
        elif channel_name == AUTOMOD_WORD:
            with session() as conn:
                automod.refresh(conn)
        elif channel_name == BLOCKED_DOMAIN:
            with session() as conn:
                screening.refresh(conn)
        elif channel_name == PURGE:
            start_purge(case_channel.client, payload)
        elif channel_name == JOIN_REQUEST:
            start_join_request(case_channel.client, payload)
        elif channel_name == CHANNEL_GUARD:
            with session() as conn:
                channelguards.refresh(conn)
            threading.Thread(
                target=join_and_post_notices, args=(case_channel.client, payload),
                name=f"nemo-seat-{payload}", daemon=True,
            ).start()
            wake_lapses()
        elif channel_name == MEMBER_GUARD:
            wake_member_guards()
            wake_lapses()
        elif channel_name == CONVERSATION:
            run_each(("catching up", lambda: case_channel.sync_case(payload)),
                     ("ticking", case_channel.mark_outbox_results))
        else:
            case_channel.sync_case(payload)

    return (
        loops.start_listener(NAME,
                       (CASES, CHAT, OUTBOX, CONVERSATION, GUARD, CHANNEL_GUARD,
                        MEMBER_GUARD, APP_SETTING, AUTOMOD_WORD, PURGE,
                        GUARD_NOTICE, GUARD_REMOVE, JOIN_REQUEST, BLOCKED_DOMAIN,
                        AUDIT_EVENT, AUTOMOD_MATCH, BOT_KICK, CATEGORY),
                       on_notify, stopping),
        loops.run_periodically(NAME, sweep_interval_seconds(), lambda: sweep_once(case_channel, channel_id), stopping),
        loops.run_periodically(f"{NAME}-joins", join_sweep_interval_seconds(), lambda: join_sweep(case_channel, stopping),
                       stopping),
        loops.run_periodically(f"{NAME}-usergroups", usergroups.REFRESH_SECONDS,
                               lambda: usergroups.refresh(case_channel.client), stopping),
    )
