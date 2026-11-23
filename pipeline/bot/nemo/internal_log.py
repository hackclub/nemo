import datetime as dt
import logging
import threading

from bot.core import session
from bot.core.formatting import short_end_token
from bot.nemo import channel, memberguards
from bot.nemo.enforcement.sweep import EXPIRED_REASON
from bot.nemo.guard_notices import quoted
from bot.nemo.views import lengths
from bot.nemo.views.activity import message_url
from bot.nemo.views.slowmode import cooldown

log = logging.getLogger("bot.nemo")

AUDIT = "audit"
AUTOMOD = "automod"
BATCH = 50
REPLACED_BY_DESTROY = "replaced by a destroy"
SYSTEM_ACTORS = (None, "system", memberguards.NEMO)

ENTITY_TYPES = ["member_guard", "channel_guard", "channel_allow", "thread_guard", "member_photo"]
VERBS = ["opened", "lifted", "extended", "tuned", "added", "removed", "performed"]

CURSOR = "SELECT last_id FROM fd.log_cursors WHERE name = %s"
MOVE_CURSOR = "UPDATE fd.log_cursors SET last_id = %s, updated_at = now() WHERE name = %s"

AUDIT_ENTRIES = """
SELECT id, actor_user_id, entity_type, entity_id, verb, before, after
FROM fd.audit
WHERE id > %s AND occurred_at > now() - interval '7 days' AND actor_kind <> 'import'
  AND entity_type = ANY(%s) AND verb = ANY(%s)
ORDER BY id
LIMIT %s
"""

AUTOMOD_MATCHES = """
SELECT id, word, user_id, channel_id, permalink, body
FROM fd.automod_matches
WHERE id > %s
ORDER BY id
LIMIT %s
"""

MEMBER_GUARD = """
SELECT kind, subject_id, channel_id, reason, expires_at, lift_reason
FROM fd.member_guards WHERE id = %s
"""

CHANNEL_GUARD = """
SELECT kind, channel_id, thread_ts, settings, reason, expires_at
FROM fd.channel_guards WHERE id = %s
"""

THREAD_GUARD = """
SELECT kind, channel_id, thread_ts, reason, expires_at, state, error
FROM fd.thread_guards WHERE id = %s
"""

PHOTO_REMOVAL = "SELECT member_id, reason FROM fd.photo_removals WHERE id = %s"

MEMBER_LABELS = {"shush": "Shush", "channel_ban": "Channel ban", "deactivation": "Deactivation"}
MEMBER_VERBS = {"shush": "shushed", "channel_ban": "banned", "deactivation": "deactivated"}
CHANNEL_LABELS = {"slowmode": "Slow mode", "readonly": "Read-only", "account_age": "New-account age",
                  "bot_allowlist": "Bot allow list"}

_lock = threading.Lock()


def actor_suffix(actor):
    return f" by <@{actor}>" if actor not in SYSTEM_ACTORS else ""


def reason_part(reason):
    return f" for *{reason}*" if reason else ""


def parsed_end(values):
    try:
        return dt.datetime.fromisoformat(str((values or {}).get("expires_at")))
    except ValueError:
        return None


def extension_word(entry):
    before, after = parsed_end(entry["before"]), parsed_end(entry["after"])
    return "shortened" if before and after and after < before else "extended"


def end_part(expires_at):
    return f"to {short_end_token(expires_at)}" if expires_at else "with no end date"


def thread_link(channel_id, thread_ts):
    return f"<{message_url(channel_id, thread_ts)}|thread>"


def member_where(kind, channel_id):
    if not channel_id:
        return ""
    preposition = "from" if kind == "channel_ban" else "in"
    return f" {preposition} <#{channel_id}>"


def member_line(entry, row):
    kind, subject_id, channel_id, reason, expires_at, lift_reason = row
    label = MEMBER_LABELS.get(kind, kind)
    where = member_where(kind, channel_id)
    verb, actor, after = entry["verb"], entry["actor"], entry["after"] or {}
    if verb == "opened":
        return (f"<@{subject_id}> {MEMBER_VERBS.get(kind, kind)}{where} "
                f"{lengths.logged_ends(expires_at)}{reason_part(reason)}{actor_suffix(actor)}")
    if verb == "extended":
        return f"<@{subject_id}> {label.lower()} {extension_word(entry)} {end_part(expires_at)}{actor_suffix(actor)}"
    if verb == "lifted":
        why = after.get("lift_reason") or lift_reason
        if why == EXPIRED_REASON or actor in SYSTEM_ACTORS:
            return f"{label} ended for <@{subject_id}>{where}"
        return f"{label} lifted for <@{subject_id}>{where}{reason_part(why)}{actor_suffix(actor)}"
    return None


def channel_where(channel_id, thread_ts):
    return f"<#{channel_id}>" + (f" {thread_link(channel_id, thread_ts)}" if thread_ts else "")


def channel_details(kind, settings, expires_at):
    settings = settings or {}
    if kind == "slowmode":
        end = f"until {short_end_token(expires_at)}" if expires_at else "and no end date"
        details = f" with {cooldown(int(settings.get('seconds') or 0))} cooldown {end}"
        if settings.get("threads"):
            return details + (" and threads" if expires_at else ", threads")
        return details
    if kind == "account_age":
        return f" with {int(settings.get('min_age_days') or 0)} days"
    if kind == "readonly" and settings.get("threads"):
        return ", threads"
    return ""


def channel_line(entry, row):
    kind, channel_id, thread_ts, settings, reason, expires_at = row
    label = CHANNEL_LABELS.get(kind, kind)
    where = channel_where(channel_id, thread_ts)
    verb, actor = entry["verb"], entry["actor"]
    if verb == "opened":
        return f"{label} enabled on {where}{channel_details(kind, settings, expires_at)}" \
               f"{reason_part(reason)}{actor_suffix(actor)}"
    if verb == "tuned":
        return f"{label} updated on {where}{channel_details(kind, settings, expires_at)}{actor_suffix(actor)}"
    if verb == "extended":
        return f"{label} {extension_word(entry)} on {where} {end_part(expires_at)}{actor_suffix(actor)}"
    if verb == "lifted":
        if actor in SYSTEM_ACTORS:
            return f"{label} ended on {where}"
        return f"{label} disabled on {where}{actor_suffix(actor)}"
    return None


def allow_line(entry, row):
    kind, channel_id, thread_ts, _settings, _reason, _expires_at = row
    subject_id = (entry["after"] or {}).get("subject_id") or (entry["before"] or {}).get("subject_id")
    if not subject_id:
        return None
    where = channel_where(channel_id, thread_ts)
    if kind == "bot_allowlist":
        verb = "Bot allowed" if entry["verb"] == "added" else "Bot removed from the allow list"
        return f"{verb} on {where} for <@{subject_id}>{actor_suffix(entry['actor'])}"
    verb = "added" if entry["verb"] == "added" else "removed"
    return f"Exemption from {CHANNEL_LABELS.get(kind, kind)} {verb} on {where} " \
           f"for <@{subject_id}>{actor_suffix(entry['actor'])}"


def thread_line(entry, row):
    kind, channel_id, thread_ts, reason, expires_at, state, error = row
    if kind != "lock":
        return None
    where = f"<#{channel_id}> {thread_link(channel_id, thread_ts)}"
    verb, actor = entry["verb"], entry["actor"]
    if verb == "opened":
        return f"Lock on {where} {lengths.logged_ends(expires_at)}{reason_part(reason)}{actor_suffix(actor)}"
    if verb == "extended":
        return f"Lock on {where} {extension_word(entry)} {end_part(expires_at)}{actor_suffix(actor)}"
    if verb == "lifted":
        if state == "failed" or error == REPLACED_BY_DESTROY:
            return None
        if actor in SYSTEM_ACTORS:
            return f"Lock on {where} ended"
        return f"Lock on {where} unlocked{actor_suffix(actor)}"
    return None


def photo_line(entry, row):
    member_id, reason = row
    if entry["verb"] != "performed":
        return None
    return f"Pfp removed for <@{member_id}>{reason_part(reason)}{actor_suffix(entry['actor'])}"


LINE_BUILDERS = {
    "member_guard": (MEMBER_GUARD, member_line),
    "channel_guard": (CHANNEL_GUARD, channel_line),
    "channel_allow": (CHANNEL_GUARD, allow_line),
    "thread_guard": (THREAD_GUARD, thread_line),
    "member_photo": (PHOTO_REMOVAL, photo_line),
}


def line_for(conn, entry):
    sql, build = LINE_BUILDERS[entry["entity_type"]]
    row = conn.execute(sql, (entry["entity_id"],)).fetchone()
    return build(entry, row) if row else None


def automod_line(match):
    _match_id, word, user_id, channel_id, permalink, body = match
    link = f" (<{permalink}|message>)" if permalink else ""
    return f'Automod matched "{word}" from <@{user_id}> in <#{channel_id}>{link}' + quoted(body)


def cursor(conn, name):
    row = conn.execute(CURSOR, (name,)).fetchone()
    return row[0] if row else 0


def advance_cursor(name, last_id):
    with session() as conn:
        conn.execute(MOVE_CURSOR, (last_id, name))


def post_text(client, log_channel_id, text, thread_ts=None):
    return client.chat_postMessage(channel=log_channel_id, text=text, thread_ts=thread_ts,
                                   unfurl_links=False, unfurl_media=False)


def post_lines(client, name, lines, log_channel_id):
    handled = 0
    for line_id, text in lines:
        if text and log_channel_id:
            try:
                post_text(client, log_channel_id, text)
            except Exception as failure:
                log.warning("nemo: internal log line %s %s not posted: %s", name, line_id, failure)
                break
        advance_cursor(name, line_id)
        handled += 1
    return handled


def audit_lines(conn):
    entries = conn.execute(AUDIT_ENTRIES, (cursor(conn, AUDIT), ENTITY_TYPES, VERBS, BATCH)).fetchall()
    keys = ("id", "actor", "entity_type", "entity_id", "verb", "before", "after")
    return [(one[0], line_for(conn, dict(zip(keys, one)))) for one in entries]


def automod_lines(conn):
    matches = conn.execute(AUTOMOD_MATCHES, (cursor(conn, AUTOMOD), BATCH)).fetchall()
    return [(one[0], automod_line(one)) for one in matches]


def drain(client):
    if not _lock.acquire(blocking=False):
        return 0
    try:
        with session() as conn:
            log_channel_id = channel.log_channel(conn)
            audits = audit_lines(conn)
            automods = automod_lines(conn)
        return post_lines(client, AUDIT, audits, log_channel_id) + post_lines(client, AUTOMOD, automods, log_channel_id)
    finally:
        _lock.release()
