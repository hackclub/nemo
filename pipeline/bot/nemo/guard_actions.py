import logging
import threading

from bot.core import privileged, session
from bot.nemo import channel, guards, profile

log = logging.getLogger("bot.nemo")

_running = set()
_lock = threading.Lock()


def claim(guard_id):
    with _lock:
        if guard_id in _running:
            return False
        _running.add(guard_id)
        return True


def drop(guard_id):
    with _lock:
        _running.discard(guard_id)


def invite_the_admin(client, channel_id):
    who = privileged.admin_user_id()
    if not who:
        return False
    try:
        client.conversations_invite(channel=channel_id, users=who)
    except Exception as failure:
        if "already_in_channel" not in str(failure):
            log.warning("nemo: could not invite %s into %s: %s", who, channel_id, failure)
            return False
    log.info("nemo: invited %s into %s so the messages can be removed", who, channel_id)
    return True


def remove(client, channel_id, ts, max_retries=2):
    try:
        privileged.delete_message(channel_id, ts, max_retries=max_retries)
        return True
    except Exception as failure:
        if not privileged.absent(failure):
            raise
        log.info("nemo: the admin account is not in %s, inviting it", channel_id)

    if not invite_the_admin(client, channel_id):
        raise RuntimeError(f"the admin account is not in {channel_id} and could not be invited")

    privileged.delete_message(channel_id, ts, max_retries=max_retries)
    return True


def archive_url(channel_id, thread_ts):
    return channel.app_url(f"/cdn/destroy/{channel_id}_{thread_ts}")


def post_destroy_notice(client, conn, channel_id, thread_ts, by):
    notice = f"A thread has been destroyed by <@{by}> in <#{channel_id}>."
    url = archive_url(channel_id, thread_ts)
    if url:
        notice += f"\narchive: {url}"

    try:
        client.chat_postMessage(
            channel=channel.internal_log_channel(conn), text=notice, unfurl_links=False
        )
    except Exception as failure:
        log.warning("nemo: could not say that %s was destroyed: %s", channel_id, failure)


def signed(by):
    return {
        "type": "context",
        "elements": [{"type": "mrkdwn", "text": f"Fire Department \u00b7 <@{by}>"}],
    }


def leave_note(client, guard_id, channel_id, thread_ts, by):
    with session() as conn:
        kept = guards.note_for(conn, guard_id)
    if kept is None:
        return None

    note, text, already = kept
    if already:
        return already
    if not note:
        return None

    try:
        answer = client.chat_postMessage(
            channel=channel_id, thread_ts=thread_ts, text=text,
            blocks=[note, signed(by)], unfurl_links=False,
        )
    except Exception as failure:
        log.warning("nemo: guard %s could not leave the note: %s", guard_id, failure)
        return None

    ts = (answer or {}).get("ts")
    if ts:
        with session() as conn:
            guards.note_posted(conn, guard_id, ts)
    return ts


def notice_still_posted(messages, thread_ts, note_ts=None):
    kept = {thread_ts, note_ts} if note_ts else {thread_ts}
    stamps = [one["ts"] for one in messages if one.get("ts") and one["ts"] not in kept]
    return stamps or [thread_ts]


def names_for(client, messages):
    named = {}
    for one in messages:
        user_id = one.get("user")
        if not user_id or user_id in named:
            continue
        named[user_id] = profile.profile(client, user_id)["name"]
    return named


def run_destroy(client, guard_id):
    if not claim(guard_id):
        return 0
    try:
        return destroy(client, guard_id)
    finally:
        drop(guard_id)


def destroy(client, guard_id):
    with session() as conn:
        guard = guards.by_id(conn, guard_id)
        if guard is None:
            return 0
        gid, kind, channel_id, thread_ts, state, by, _warned, _expires = guard
        if kind != guards.DESTROY or state not in ("warned", "running"):
            return 0
        guards.start(conn, gid)

    try:
        messages = guards.transcript(client, channel_id, thread_ts)
    except Exception as failure:
        log.warning("nemo: guard %s could not read the thread: %s", gid, failure)
        with session() as conn:
            guards.finish(conn, gid, "failed", f"could not read the thread: {failure}")
            guards.refresh(conn)
        return 0

    named = names_for(client, messages)
    with session() as conn:
        guards.keep_transcript(conn, gid, channel_id, thread_ts, messages, named)
    log.info("nemo: guard %s kept %s message(s) before deleting", gid, len(messages))

    note_ts = leave_note(client, gid, channel_id, thread_ts, by)

    deleted, failed = 0, None
    for _ in range(guards.MAX_PASSES):
        try:
            messages = guards.transcript(client, channel_id, thread_ts)
        except Exception as failure:
            if "thread_not_found" in str(failure):
                break
            failed = str(failure)[:200]
            break

        stamps = notice_still_posted(messages, thread_ts, note_ts)

        gone = 0
        for ts in stamps:
            try:
                remove(client, channel_id, ts)
                gone += 1
            except Exception as failure:
                log.warning("nemo: guard %s could not delete %s: %s", gid, ts, failure)

        deleted += gone
        with session() as conn:
            guards.progressed(conn, gid, gone)

        if gone == 0:
            failed = "slack refused every delete in a pass"
            break
        if stamps == [thread_ts]:
            break

    with session() as conn:
        guards.finish(conn, gid, "failed" if failed else "done", failed, None)
        guards.refresh(conn)
        if not failed:
            post_destroy_notice(client, conn, channel_id, thread_ts, by)

    log.info("nemo: guard %s destroyed %s message(s)%s", gid, deleted,
             f", stopped on {failed}" if failed else "")
    return deleted


def lift_lock(client, guard_id):
    with session() as conn:
        guard = guards.by_id(conn, guard_id)
        if guard is None:
            return None
        gid, kind, channel_id, _thread_ts, state, _by, _warned, _expires = guard
        if kind != guards.LOCK or state not in ("warned", "running"):
            return None
        guards.finish(conn, gid, "done")
        guards.refresh(conn)

    log.info("nemo: guard %s lifted the lock on %s", gid, channel_id)
    return gid


def note_it(conn, guard, user_id, ts):
    gid, _kind, channel_id, _thread_ts, _state, _by, warned_ts, _expires = guard

    if warned_ts is None or ts <= warned_ts:
        return False

    guards.kept(conn, gid, channel_id, user_id, ts)
    return True


def delete_notice(client, guard_id, channel_id, ts):
    try:
        remove(client, channel_id, ts)
    except Exception as failure:
        if not privileged.gone(failure):
            log.warning("nemo: guard %s could not remove %s yet: %s", guard_id, ts, failure)
            return False
        log.info("nemo: guard %s found %s already gone", guard_id, ts)

    with session() as conn:
        guards.removed(conn, guard_id, ts)
    return True


def threshold_met(guard, user_id):
    gid, _kind, channel_id, thread_ts, _state, _by, _warned, _expires = guard

    with session() as conn:
        count = guards.record_strike(conn, gid, user_id)
    if count < privileged.strikes_needed():
        return None

    outcome = escalate(gid, user_id, channel_id, thread_ts, count)
    if outcome:
        log.warning("nemo: guard %s -> sessions %s for %s after %s message(s)",
                    gid, outcome, user_id, count)
    return outcome


STILL_UP_PER_SWEEP = 200


def sweep_removals(client):
    with session() as conn:
        waiting = guards.still_up(conn, STILL_UP_PER_SWEEP)
    if not waiting:
        return 0

    gone = 0
    for guard_id, channel_id, ts in waiting:
        if delete_notice(client, guard_id, channel_id, ts):
            gone += 1

    log.info("nemo: cleared %s of %s message(s) the guard could not remove first time",
             gone, len(waiting))
    return gone


def escalate(guard_id, user_id, channel_id, thread_ts, messages):
    if privileged.mode() == privileged.OFF:
        return None

    with session() as conn:
        cap = privileged.cap_per_guard()
        if cap and guards.strike_count(conn, guard_id) >= cap:
            log.warning("nemo: guard %s hit the reset cap of %s, leaving %s alone",
                        guard_id, cap, user_id)
            return None
        if not guards.claim_reset(conn, guard_id, user_id, messages):
            return None

    outcome = privileged.reset_sessions(user_id)

    with session() as conn:
        guards.reset_done(conn, guard_id, user_id, outcome, channel_id, thread_ts, messages)
    return outcome


def sweep_strikes():
    needed = privileged.strikes_needed()
    with session() as conn:
        over = guards.over_the_line(conn, needed)

    done = 0
    for guard_id, user_id, messages, channel_id, thread_ts in over:
        if not claim(guard_id):
            continue
        try:
            outcome = escalate(guard_id, user_id, channel_id, thread_ts, messages)
        except Exception as failure:
            log.warning("nemo: guard %s could not escalate %s: %s", guard_id, user_id, failure)
            continue
        finally:
            drop(guard_id)

        if outcome:
            done += 1
            log.warning("nemo: guard %s -> sessions %s for %s after %s message(s)",
                        guard_id, outcome, user_id, messages)
    return done
