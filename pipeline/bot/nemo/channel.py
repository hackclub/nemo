import functools
import hashlib
import logging
import os
import time

from psycopg.types.json import Jsonb

from bot.core import parse, whoami
from bot.core.formatting import quote_text
from bot.nemo import answer, views, attachments, card_facts, channels, chat, profile
from bot.nemo.views.activity import message_url
from lib.paths import WEB_DIR
from lyla import claim

log = logging.getLogger("bot.nemo")


CASE = """
SELECT c.id, c.category_key, c.resolved_at,
       r.id, r.is_anonymous, r.reporter_user_id, r.body, r.forwarded_ts, r.received_at,
       v.id, r.card_digest, c.resolution, r.card_channel_id, r.header_ts, r.header_digest,
       r.entry_point, c.source_app = 'lyla'
FROM fd.cases c
JOIN fd.case_reports r ON r.case_id = c.id
LEFT JOIN fd.intake_conversations v ON v.report_id = r.id
WHERE c.id = %s
ORDER BY r.id
LIMIT 1
"""


SUBJECTS = """
SELECT user_id FROM fd.case_participants
WHERE case_id = %s AND role = 'subject'
ORDER BY user_id
"""


ASSIGNEES = """
SELECT user_id FROM fd.case_assignees WHERE case_id = %s ORDER BY assigned_at
"""


FIRST_MESSAGE = """
SELECT m.id, m.body, m.mirrored_ts, m.blocks, coalesce(o.body, m.body)
FROM fd.intake_messages m
LEFT JOIN fd.intake_revisions o ON o.message_id = m.id AND o.seq = 0
WHERE m.conversation_id = %s AND m.direction = 'inbound'
ORDER BY m.posted_at, m.id
LIMIT 1
"""


INBOUND_MESSAGES = """
SELECT m.id, coalesce(o.body, m.body), m.posted_at, m.mirrored_ts, m.deleted_at,
       c.handed_off_at
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
LEFT JOIN fd.intake_revisions o ON o.message_id = m.id AND o.seq = 0
WHERE m.conversation_id = %s AND m.direction = 'inbound'
ORDER BY m.posted_at, m.id
"""


CONVERSATION_SHARES = """
SELECT s.message_id, s.kind, s.source_channel_id, s.source_ts, s.permalink
FROM fd.intake_shares s
JOIN fd.intake_messages m ON m.id = s.message_id
WHERE m.conversation_id = %s
ORDER BY s.id
"""


ENTRY_POINT_OF_MESSAGE = """
SELECT r.entry_point
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE m.id = %s
"""


LOCK_UNFURL = """
SELECT conversation_id, unfurl_ts, unfurl_digest, unfurled_at
FROM fd.intake_messages WHERE id = %s
FOR UPDATE
"""


SET_UNFURL = """
UPDATE fd.intake_messages
SET unfurl_ts = coalesce(%s, unfurl_ts), unfurl_digest = %s,
    unfurled_at = coalesce(unfurled_at, now())
WHERE id = %s
"""


FORWARDED_FILES = """
SELECT mf.file_id, f.slack_file_id, f.name, f.mimetype, f.stored_key, mf.mirrored_file_id
FROM fd.intake_message_files mf
JOIN fd.intake_files f ON f.id = mf.file_id
WHERE mf.message_id = %s AND mf.forwarded AND f.fetch_state = 'stored'
ORDER BY mf.seq
"""


UNFURLS_ON_CASE = """
SELECT m.id, r.forwarded_ts, r.card_channel_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE r.case_id = %s AND r.forwarded_ts IS NOT NULL AND m.direction = 'inbound'
  AND m.mirrored_ts IS NOT NULL AND m.deleted_at IS NULL
  AND (m.unfurled_at IS NULL OR m.unfurl_ts IS NOT NULL)
ORDER BY m.posted_at, m.id
"""


LIVE_ACTION_COUNT = """
SELECT count(*) FROM fd.actions WHERE case_id = %s AND reversed_at IS NULL
"""


SHARES = """
SELECT s.kind, s.source_channel_id, s.source_channel_name, s.source_ts, s.permalink,
       s.is_reachable, s.source_author_user_id, s.source_body, s.raw
FROM fd.intake_shares s
WHERE s.message_id = %s
ORDER BY s.id
"""


CLAIM_CARD = """
SELECT forwarded_ts FROM fd.case_reports WHERE id = %s FOR UPDATE
"""


FOLLOW_UP = """
SELECT m.body, m.mirrored_ts, r.forwarded_ts, m.conversation_id,
       r.is_anonymous, r.reporter_user_id, r.card_channel_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
LEFT JOIN fd.case_reports r ON r.id = c.report_id
WHERE m.id = %s
"""


ANONYMOUS = "Anonymous"

ANONYMOUS_ICON_PATH = "/anonymous.png"
ANONYMOUS_ICON_FILE = WEB_DIR / "public" / "anonymous.png"
ICON_VERSION_LENGTH = 12


def digest_of(blocks, mark=None):
    return parse.digest(mark, blocks, None)


OPEN_MARK = "hourglass_flowing_sand"
MERGED_MARK = "repeat"
DONE_MARK = "white_check_mark"
NOT_CONDUCT_MARK = "x"
CARD_MARKS = (OPEN_MARK, MERGED_MARK, DONE_MARK, NOT_CONDUCT_MARK, "check")
CLOSED_MARKS = (DONE_MARK, NOT_CONDUCT_MARK)
NOT_CONDUCT_MARKS = (NOT_CONDUCT_MARK, "heavy_multiplication_x", "negative_squared_cross_mark")
RESOLVE_REACTIONS = ("white_check_mark", "heavy_check_mark", "ballot_box_with_check", "white_tick", "check")
RESOLVE_REACTION_PREFIX = "check-"
IGNORED_REACTION_ERRORS = ("already_reacted", "no_reaction")


DIGEST_PREFIX = "mark:"


def card_state(mark):
    return f"{DIGEST_PREFIX}{mark or ''}"


def has_legacy_digest(stored):
    return not str(stored or "").startswith(DIGEST_PREFIX)


def card_mark(case):
    if not case.get("resolved_at"):
        return None if case.get("mark_held") else OPEN_MARK
    if case.get("resolution") == "duplicate":
        return MERGED_MARK
    return NOT_CONDUCT_MARK if case.get("resolution") == "not_conduct" else DONE_MARK


def reaction_base_name(name):
    return (name or "").split("::")[0]


def is_resolve_reaction(name):
    return name in RESOLVE_REACTIONS or (
        name.startswith(RESOLVE_REACTION_PREFIX) and len(name) > len(RESOLVE_REACTION_PREFIX)
    )


def is_close_reaction(name):
    return is_resolve_reaction(name) or name in NOT_CONDUCT_MARKS


def has_human_close_reaction(client, channel_id, ts, bot_user_id):
    response = client.reactions_get(channel=channel_id, timestamp=ts, full=True)
    for reaction in ((response or {}).get("message") or {}).get("reactions") or []:
        if not is_close_reaction(reaction_base_name(reaction.get("name"))):
            continue
        if any(user_id != bot_user_id for user_id in reaction.get("users") or []):
            return True
    return False


def mark_to_add(client, channel_id, ts, target_mark):
    if target_mark not in CLOSED_MARKS:
        return target_mark
    try:
        closed_by_reaction = has_human_close_reaction(
            client, channel_id, ts, whoami.bot_user_id(client, "nemo"))
    except Exception as failure:
        log.warning("nemo: could not read the reactions on %s: %s", ts, failure)
        return target_mark
    return None if closed_by_reaction else target_mark


def react(client, method, channel_id, ts, name):
    try:
        getattr(client, method)(channel=channel_id, timestamp=ts, name=name)
    except Exception as failure:
        if not any(one in str(failure) for one in IGNORED_REACTION_ERRORS):
            log.warning("nemo: could not change %s on %s: %s", name, ts, failure)


def mark_card(client, channel_id, ts, case, is_new=False):
    target_mark = mark_to_add(client, channel_id, ts, card_mark(case))
    if not is_new:
        for name in CARD_MARKS:
            if name != target_mark:
                react(client, "reactions_remove", channel_id, ts, name)
    if target_mark:
        react(client, "reactions_add", channel_id, ts, target_mark)


def root_mark(case):
    return card_mark(case) if case.get("resolved_at") else None


def mark_root(client, channel_id, root_ts, card_ts, case, is_new=False):
    target_mark = mark_to_add(client, channel_id, root_ts, root_mark(case))
    if not is_new:
        for name in CARD_MARKS:
            if name != target_mark:
                react(client, "reactions_remove", channel_id, root_ts, name)
            react(client, "reactions_remove", channel_id, card_ts, name)
    if target_mark:
        react(client, "reactions_add", channel_id, root_ts, target_mark)


_settings = {}


def channel_setting(key, conn=None):
    if conn is not None:
        _settings[key] = channels.setting(conn, key) or None
    return _settings.get(key)


def firehouse_channel(conn=None):
    return channel_setting(channels.FIREHOUSE, conn)


def reports_channel(conn=None):
    return channel_setting(channels.REPORTS, conn)


def log_channel(conn=None):
    return channel_setting(channels.LOGS, conn)


_react = {}


def react_channels(conn=None):
    if conn is not None:
        _react["ids"] = channels.react_channels(conn)
    return _react.get("ids") or set()


CARD_CHANNELS = """
SELECT card_channel_id FROM fd.case_reports WHERE card_channel_id IS NOT NULL
UNION
SELECT card_channel_id FROM fd.cases WHERE card_channel_id IS NOT NULL
"""

_cards = {}


def card_channels(conn=None):
    if conn is not None:
        _cards["ids"] = {row[0] for row in conn.execute(CARD_CHANNELS).fetchall()}
    return _cards.get("ids") or set()


def refresh_channels(conn):
    firehouse_channel(conn)
    reports_channel(conn)
    log_channel(conn)
    react_channels(conn)
    card_channels(conn)


def case_channels(conn=None):
    fixed_ids = {firehouse_channel(conn), reports_channel(conn)}
    return (fixed_ids | react_channels(conn) | card_channels(conn)) - {None}


def card_channel(case, channel_id=None, conn=None):
    return channel_or_firehouse(case.get("card_channel_id"), channel_id, conn)


def channel_or_firehouse(stored, channel_id=None, conn=None):
    return stored or channel_id or firehouse_channel(conn)


CARD_CHANNEL_FOR_CASE = """
SELECT coalesce(
    (SELECT r.card_channel_id FROM fd.case_reports r
      WHERE r.case_id = %(case_id)s AND r.forwarded_ts IS NOT NULL
      ORDER BY r.id LIMIT 1),
    (SELECT k.card_channel_id FROM fd.cases k WHERE k.id = %(case_id)s)
)
"""


def card_channel_for(conn, case_id, channel_id=None):
    row = conn.execute(CARD_CHANNEL_FOR_CASE, {"case_id": case_id}).fetchone()
    return (row and row[0]) or channel_id or firehouse_channel(conn)


THREAD_FOR_CASE = """
SELECT coalesce(
    (SELECT r.forwarded_ts FROM fd.case_reports r
      WHERE r.case_id = %(case_id)s AND r.forwarded_ts IS NOT NULL
      ORDER BY r.id LIMIT 1),
    (SELECT coalesce(k.card_thread_ts, k.card_ts) FROM fd.cases k WHERE k.id = %(case_id)s)
)
"""


def thread_for(conn, case_id):
    row = conn.execute(THREAD_FOR_CASE, {"case_id": case_id}).fetchone()
    return row[0] if row else None


def post_line(client, conn, case_id, text):
    thread = thread_for(conn, case_id)
    if not thread:
        return None
    try:
        return client.chat_postMessage(
            channel=card_channel_for(conn, case_id),
            thread_ts=thread,
            text=text,
            unfurl_links=False,
            unfurl_media=False,
        )["ts"]
    except Exception as failure:
        log.warning("nemo: case %s did not hear %r: %s", case_id, text[:60], failure)
        return None


def post_merge_note(client, conn, target_id, closed, by):
    if not closed:
        return None
    entries = views.lines.merged(by, closed, target_id, case_url)
    for case_id, text in entries:
        post_line(client, conn, case_id, text)
    return entries


SET_HEADER_TS = """
UPDATE fd.case_reports SET header_ts = %s, header_digest = %s WHERE id = %s AND header_ts IS NULL
"""

SET_HEADER_DIGEST = """
UPDATE fd.case_reports SET header_digest = %s WHERE id = %s
"""


def post_header(client, conn, case, card_channel_id, thread_ts):
    if case.get("header_ts") or case.get("resolved_at") or not views.report.needs_header(case):
        return None
    card_facts.enrich(client, conn, case, case_url)
    try:
        sent = client.chat_postMessage(
            channel=card_channel_id,
            thread_ts=thread_ts,
            unfurl_links=False,
            unfurl_media=False,
            **views.case_card.render(case),
        )
    except Exception as failure:
        log.warning("nemo: case %s has no header in its thread: %s", case["case_id"], failure)
        return None
    conn.execute(SET_HEADER_TS, (sent["ts"], views.case_card.digest(case), case["report_id"]))
    return sent["ts"]


def sync_header(client, conn, case, card_channel_id):
    extra = {}
    if views.report.needs_header(case):
        if not case.get("header_ts"):
            return post_header(client, conn, case, card_channel_id, case["forwarded_ts"])
        target_ts = case["header_ts"]
    else:
        target_ts = case["forwarded_ts"]
        extra["metadata"] = views.report.metadata(case)

    card_facts.enrich(client, conn, case, case_url)
    digest = views.case_card.digest(case)
    if digest == case.get("header_digest"):
        return target_ts
    try:
        client.chat_update(channel=card_channel_id, ts=target_ts, **extra, **views.case_card.render(case))
    except Exception as failure:
        if not is_foreign_message_error(failure):
            raise
        log.warning("nemo: case %s keeps its header as it was, slack would not edit it: %s",
                    case["case_id"], failure)
    conn.execute(SET_HEADER_DIGEST, (digest, case["report_id"]))
    return target_ts


def read_linked(client, conn, channel_id, ts, thread_ts=None):
    channels.join_public(client, conn, channel_id)
    try:
        if thread_ts and thread_ts != ts:
            response = client.conversations_replies(
                channel=channel_id, ts=thread_ts, oldest=ts, latest=ts, inclusive=True, limit=5
            )
        else:
            response = client.conversations_history(
                channel=channel_id, oldest=ts, latest=ts, inclusive=True, limit=1
            )
    except Exception as failure:
        log.info("nemo: could not read %s in %s: %s", ts, channel_id, failure)
        return None
    message = next((one for one in response.get("messages") or [] if one.get("ts") == ts), None)
    if message is None:
        return None
    return {
        "kind": "link",
        "source_channel_id": channel_id,
        "source_ts": ts,
        "source_author_user_id": message.get("user"),
        "source_body": message.get("text"),
        "permalink": None,
        "is_reachable": bool((message.get("text") or "").strip()),
        "raw": None,
    }


def linked_shares(client, conn, text):
    shares, visited = [], set()
    for one in views.linked.occurrences(text):
        key = (one["channel_id"], one["ts"])
        if key in visited:
            continue
        visited.add(key)
        share = read_linked(client, conn, one["channel_id"], one["ts"], one["thread_ts"])
        if share:
            shares.append(share)
    return shares


UNREAD_LINKS = """
SELECT id, source_channel_id, source_ts, source_thread_ts
FROM fd.intake_shares
WHERE message_id = %s AND kind = 'link' AND NOT is_reachable
ORDER BY id
"""

SET_LINK_READ = """
UPDATE fd.intake_shares
SET source_author_user_id = %s, source_body = %s, is_reachable = true
WHERE id = %s
"""


def read_links(client, conn, message_id):
    unread = conn.execute(UNREAD_LINKS, (message_id,)).fetchall()
    for share_id, channel_id, ts, thread_ts in unread:
        linked_message = read_linked(client, conn, channel_id, ts, thread_ts)
        if linked_message and linked_message["is_reachable"]:
            conn.execute(SET_LINK_READ, (linked_message["source_author_user_id"],
                                         linked_message["source_body"], share_id))


OPENING_TO_UNFURL = """
SELECT id, body FROM fd.case_chat
WHERE case_id = %s AND mirrored_as = 'card' AND deleted_at IS NULL AND unfurl_ts IS NULL
ORDER BY id LIMIT 1
"""

OPENING_UNFURLED = "UPDATE fd.case_chat SET unfurl_ts = %s WHERE id = %s AND unfurl_ts IS NULL"


def unfurl_opening(client, conn, case_id, channel_id, thread_ts):
    row = conn.execute(OPENING_TO_UNFURL, (case_id,)).fetchone()
    if row is None:
        return None
    chat_id, body = row
    numbered = views.linked.numbering(body, [], 1)
    if not numbered["links"]:
        return None
    items = views.linked.items(numbered, linked_shares(client, conn, body))
    try:
        sent = client.chat_postMessage(
            channel=channel_id,
            thread_ts=thread_ts,
            text=views.linked.fallback(items),
            blocks=views.linked.reply_blocks(items),
            unfurl_links=False,
            unfurl_media=False,
        )
    except Exception as failure:
        log.warning("nemo: case %s's links would not unfurl: %s", case_id, failure)
        return None
    conn.execute(OPENING_UNFURLED, (sent["ts"], chat_id))
    return sent["ts"]


def app_url(path):
    host = os.environ.get("APP_HOST")
    if not host:
        return None
    scheme = "http" if host.startswith("localhost") or host.startswith("127.") else "https"
    return f"{scheme}://{host}{path}"


def case_url(case_id):
    return app_url(f"/fd/cases/{case_id}")


def member_url(user_id):
    return app_url(f"/fd/members/{user_id}")


def channel_url(channel_id):
    return app_url(f"/fd/channels/{channel_id}")


def fetch_case(conn, case_id):
    row = conn.execute(CASE, (case_id,)).fetchone()
    if not row:
        return None
    case = {
        "case_id": row[0],
        "category_key": row[1],
        "resolved_at": row[2],
        "report_id": row[3],
        "is_anonymous": row[4],
        "reporter_user_id": row[5],
        "body": row[6],
        "forwarded_ts": row[7],
        "received_at": row[8],
        "conversation_id": row[9],
        "card_digest": row[10],
        "resolution": row[11],
        "card_channel_id": row[12],
        "header_ts": row[13],
        "header_digest": row[14],
        "entry_point": row[15],
        "imported": row[16],
        "url": case_url(row[0]),
        "shares": [],
        "message_id": None,
        "blocks": None,
    }

    case["subjects"] = [
        subject[0] for subject in conn.execute(SUBJECTS, (case["case_id"],)).fetchall()
    ]
    case["assignees"] = [
        assignee[0] for assignee in conn.execute(ASSIGNEES, (case["case_id"],)).fetchall()
    ]
    case["live_actions"] = conn.execute(LIVE_ACTION_COUNT, (case["case_id"],)).fetchone()[0]
    case["mark_held"] = claim.waiting(conn, case["case_id"])

    conversation_id = case["conversation_id"]
    if conversation_id is None:
        return case

    first = conn.execute(FIRST_MESSAGE, (conversation_id,)).fetchone()
    if first:
        case["message_id"] = first[0]
        case["mirrored_ts"] = first[2]
        case["blocks"] = first[3]
        if not case["body"]:
            case["body"] = first[1]

    case["shares"] = shares_for(conn, case["message_id"])
    if first:
        case["numbering"] = views.linked.numbering(first[4], case["shares"], 1)
    return case


def shares_for(conn, message_id):
    return [
        {
            "kind": one[0],
            "source_channel_id": one[1],
            "source_channel_name": one[2],
            "source_ts": one[3],
            "permalink": one[4],
            "is_reachable": one[5],
            "source_author_user_id": one[6],
            "source_body": one[7],
            "raw": one[8],
        }
        for one in conn.execute(SHARES, (message_id,)).fetchall()
    ]


def message_numbering(conn, conversation_id):
    shares = {}
    for message_id, kind, channel_id, ts, permalink in conn.execute(
        CONVERSATION_SHARES, (conversation_id,)
    ).fetchall():
        shares.setdefault(message_id, []).append({
            "kind": kind, "source_channel_id": channel_id, "source_ts": ts, "permalink": permalink,
        })

    numberings = {}
    start = 1
    rows = conn.execute(INBOUND_MESSAGES, (conversation_id,)).fetchall()
    for at, (message_id, text, _posted_at, mirrored, deleted, _handed_off) in enumerate(rows):
        if at and deleted and not mirrored:
            continue
        numberings[message_id] = views.linked.numbering(text, shares.get(message_id), start)
        start += views.linked.size(numberings[message_id])
    return numberings


def forwarded_files(client, conn, message_id):
    files_by_id = {}
    uploaded = False
    for file_id, slack_file_id, name, mimetype, sha, mirrored in conn.execute(
        FORWARDED_FILES, (message_id,)
    ).fetchall():
        display_name = name or (sha or slack_file_id)[:12]
        if not attachments.shows_inline(mimetype):
            files_by_id[slack_file_id] = {"id": None, "name": display_name, "image": False}
            continue
        if not mirrored:
            body, _ = attachments.blobs.body_of(conn, sha)
            if body is None:
                continue
            mirrored = attachments.upload_file(client, display_name, body)
            if not mirrored:
                continue
            conn.execute(attachments.MARK_MIRRORED, (mirrored, message_id, file_id))
            uploaded = True
        files_by_id[slack_file_id] = {"id": mirrored, "name": display_name, "image": True}
    if uploaded:
        time.sleep(attachments.FILE_INDEX_DELAY)
    return files_by_id


def is_shortcut_report(conn, message_id):
    row = conn.execute(ENTRY_POINT_OF_MESSAGE, (message_id,)).fetchone()
    return bool(row) and row[0] == views.shortcut_report.SHORTCUT


def unfurl(client, conn, message_id, channel_id, thread_ts):
    if is_shortcut_report(conn, message_id):
        return None
    row = conn.execute(LOCK_UNFURL, (message_id,)).fetchone()
    if row is None:
        return None
    conversation_id, posted, digest, handled = row
    if handled and not posted:
        return None
    if not posted:
        read_links(client, conn, message_id)

    items = views.linked.items(
        message_numbering(conn, conversation_id).get(message_id), shares_for(conn, message_id)
    )
    blocks = views.linked.reply_blocks(items, forwarded_files(client, conn, message_id))

    if not blocks:
        if not posted:
            conn.execute(SET_UNFURL, (None, None, message_id))
        return posted

    fingerprint = digest_of(blocks)
    if posted:
        if fingerprint != digest:
            client.chat_update(
                channel=channel_id, ts=posted, text=views.linked.fallback(items), blocks=blocks
            )
            conn.execute(SET_UNFURL, (None, fingerprint, message_id))
        return posted

    sent = client.chat_postMessage(
        channel=channel_id,
        thread_ts=thread_ts,
        text=views.linked.fallback(items),
        blocks=blocks,
        unfurl_links=False,
        unfurl_media=False,
    )
    conn.execute(SET_UNFURL, (sent["ts"], fingerprint, message_id))
    log.info("nemo: message %s has its links unfurled at %s", message_id, sent["ts"])
    return sent["ts"]


def post_unfurls(client, conn, case_id, channel_id=None):
    unfurled_count = 0
    for message_id, thread_ts, stored in conn.execute(UNFURLS_ON_CASE, (case_id,)).fetchall():
        try:
            if unfurl(client, conn, message_id, channel_or_firehouse(stored, channel_id, conn), thread_ts):
                unfurled_count += 1
        except Exception as failure:
            log.warning("nemo: message %s's links would not unfurl: %s", message_id, failure)
    return unfurled_count


def post_report(client, conn, case_id, channel_id=None, thread_ts=None):
    case = fetch_case(conn, case_id)
    if case is None:
        log.warning("nemo: case %s has no report to post", case_id)
        return None
    if case["forwarded_ts"]:
        log.info("nemo: case %s already has a report card", case_id)
        return case["forwarded_ts"]

    card_channel_id = channel_id or reports_channel(conn)
    if not card_channel_id:
        log.warning("nemo: case %s waits for nemo.reports_channel to be set", case_id)
        return None

    row = conn.execute(CLAIM_CARD, (case["report_id"],)).fetchone()
    if row and row[0]:
        log.info("nemo: case %s went up while we were asking, leaving it", case_id)
        return row[0]

    if not views.report.needs_header(case):
        card_facts.enrich(client, conn, case, case_url)
    built = views.report.build_blocks(case)
    sent = client.chat_postMessage(
        channel=card_channel_id,
        thread_ts=thread_ts,
        text=views.report.fallback(case),
        blocks=built,
        metadata=views.report.metadata(case),
        unfurl_links=False,
        unfurl_media=False,
        **author_display_fields(client, case["is_anonymous"], case["reporter_user_id"]),
    )
    ts = sent["ts"]

    conn.execute(
        "UPDATE fd.case_reports SET forwarded_ts = %s, card_digest = %s, card_channel_id = %s, "
        "header_digest = %s, card_rendered_at = now() WHERE id = %s AND forwarded_ts IS NULL",
        (ts, card_state(card_mark(case)), card_channel_id,
         None if views.report.needs_header(case) else views.case_card.digest(case), case["report_id"]),
    )
    mark_card(client, card_channel_id, ts, case, is_new=True)
    post_header(client, conn, case, card_channel_id, ts)
    if case["message_id"]:
        conn.execute(
            "UPDATE fd.intake_messages SET mirrored_ts = %s, mirrored_at = now(), shown_body = %s "
            "WHERE id = %s",
            (ts, case.get("body"), case["message_id"]),
        )
        try:
            unfurl(client, conn, case["message_id"], card_channel_id, ts)
        except Exception as failure:
            log.warning("nemo: case %s's links would not unfurl: %s", case_id, failure)
    if case["message_id"]:
        attachments.share(
            client, conn, case["message_id"], card_channel_id, ts,
            author_fields=reporter_author_fields(client, case["is_anonymous"], case["reporter_user_id"]),
        )

    log.info("nemo: case %s report card posted at %s", case_id, ts)
    return ts


def anonymous_icon_url():
    icon_url = os.environ.get("ANONYMOUS_ICON_URL")
    if icon_url:
        return icon_url

    host = os.environ.get("APP_HOST", "")
    if not host or host.startswith(("localhost", "127.")):
        return None
    version = anonymous_icon_version()
    return app_url(f"{ANONYMOUS_ICON_PATH}?v={version}" if version else ANONYMOUS_ICON_PATH)


@functools.cache
def anonymous_icon_version():
    try:
        return hashlib.sha256(ANONYMOUS_ICON_FILE.read_bytes()).hexdigest()[:ICON_VERSION_LENGTH]
    except OSError:
        return None


def author_display_fields(client, anonymous, reporter_user_id):
    author_fields = reporter_author_fields(client, anonymous, reporter_user_id)
    author_fields.pop("metadata", None)
    return author_fields


def reporter_author_fields(client, anonymous, reporter_user_id):
    if anonymous or not reporter_user_id:
        author_fields = {"username": ANONYMOUS}
        icon = anonymous_icon_url()
        if icon:
            author_fields["icon_url"] = icon
        return author_fields

    member_profile = profile.profile(client, reporter_user_id)
    author_fields = {"username": member_profile["name"]}
    if member_profile["icon"]:
        author_fields["icon_url"] = member_profile["icon"]
    author_fields["metadata"] = {
        "event_type": "nemo_message",
        "event_payload": {"source_user_id": reporter_user_id},
    }
    return author_fields


def post_follow_up(client, conn, message_id, channel_id=None):
    row = conn.execute(FOLLOW_UP, (message_id,)).fetchone()
    if not row:
        return None
    body, mirrored, forwarded, conversation_id, anonymous, reporter, stored = row
    if mirrored:
        return mirrored
    if not forwarded:
        log.warning("nemo: message %s has no card to hang under", message_id)
        return None

    card_channel_id = channel_or_firehouse(stored, channel_id, conn)
    numbered = message_numbering(conn, conversation_id).get(message_id)
    ts = attachments.share(
        client, conn, message_id, card_channel_id, forwarded,
        author_fields=reporter_author_fields(client, anonymous, reporter),
        body=views.linked.numbered_text(
            views.report.escape_but_mentions(quote_text(body)), numbered
        ),
        unfurl=not (numbered and numbered["links"]),
        summary=True,
    )
    if ts is None:
        log.info("nemo: message %s had nothing to carry", message_id)
        return None

    conn.execute(
        "UPDATE fd.intake_messages SET mirrored_ts = %s, mirrored_at = now(), shown_body = %s "
        "WHERE id = %s AND mirrored_ts IS NULL",
        (ts, body, message_id),
    )
    try:
        unfurl(client, conn, message_id, card_channel_id, forwarded)
    except Exception as failure:
        log.warning("nemo: message %s's links would not unfurl: %s", message_id, failure)
    log.info("nemo: message %s carried into its card thread at %s", message_id, ts)
    return ts


EDITS_WAITING = """
SELECT m.id, m.mirrored_ts, coalesce(m.shown_body, first_revision.body), m.body,
       r.forwarded_ts, r.card_channel_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
LEFT JOIN fd.intake_revisions first_revision ON first_revision.message_id = m.id AND first_revision.seq = 0
WHERE r.case_id = %s AND m.direction = 'inbound' AND m.deleted_at IS NULL
  AND m.mirrored_ts IS NOT NULL AND r.forwarded_ts IS NOT NULL AND m.revision > 0
  AND coalesce(m.body, '') IS DISTINCT FROM coalesce(m.shown_body, first_revision.body, '')
ORDER BY m.posted_at, m.id
"""

SHOWN = "UPDATE fd.intake_messages SET shown_body = %s WHERE id = %s"


def post_edit_notices(client, conn, case_id, channel_id=None):
    posted_count = 0
    for message_id, mirrored_ts, before, after, card_ts, stored_channel in conn.execute(
        EDITS_WAITING, (case_id,)
    ).fetchall():
        card_channel_id = channel_or_firehouse(stored_channel, channel_id, conn)
        notice = views.edits.edit_notice(message_url(card_channel_id, mirrored_ts, card_ts), before, after)
        client.chat_postMessage(channel=card_channel_id, thread_ts=card_ts, unfurl_links=False,
                                unfurl_media=False, **notice)
        conn.execute(SHOWN, (after, message_id))
        posted_count += 1
        log.info("nemo: case %s noted an edit to message %s", case_id, message_id)
    return posted_count


def refresh_card(client, conn, case_id, channel_id=None):
    case = fetch_case(conn, case_id)
    if case is None:
        return None
    if case.get("imported"):
        return case["forwarded_ts"]
    if not case["forwarded_ts"]:
        return post_report(client, conn, case_id, channel_id)

    state = card_state(card_mark(case))
    card_channel_id = card_channel(case, channel_id, conn)
    if state != case["card_digest"]:
        if has_legacy_digest(case["card_digest"]):
            try:
                client.chat_update(
                    channel=card_channel_id,
                    ts=case["forwarded_ts"],
                    text=views.report.fallback(case),
                    blocks=views.report.build_blocks(case),
                )
            except Exception as failure:
                if not is_foreign_message_error(failure):
                    raise
                log.warning("nemo: case %s keeps its card as it was, slack would not edit it: %s",
                            case_id, failure)
                conn.execute(SET_CARD_DIGEST, (state, case["report_id"]))
                return case["forwarded_ts"]

        conn.execute(SET_CARD_DIGEST, (state, case["report_id"]))
        mark_card(client, card_channel_id, case["forwarded_ts"], case,
                  is_new=case["card_digest"] == card_state(None))
        log.info("nemo: case %s is now %s", case_id, state)

    sync_header(client, conn, case, card_channel_id)
    return case["forwarded_ts"]


FOREIGN_MESSAGE_ERRORS = ("cant_update_message", "message_not_found", "edit_window_closed")

SET_CARD_DIGEST = """
UPDATE fd.case_reports SET card_digest = %s, card_rendered_at = now() WHERE id = %s
"""


def is_foreign_message_error(failure):
    text = str(failure)
    return any(one in text for one in FOREIGN_MESSAGE_ERRORS)


def post_ephemeral(client, body, text):
    client.chat_postEphemeral(
        channel=body["channel"]["id"],
        user=body["user"]["id"],
        thread_ts=body["message"].get("thread_ts") or body["message"]["ts"],
        text=text,
    )


REOPEN_PROMPT_PENDING = """
SELECT resolved_at IS NOT NULL FROM fd.cases
WHERE id = %s AND reporter_replied_at IS NOT NULL AND reopen_prompt_posted_at IS NULL
"""


MARK_REOPEN_PROMPT_POSTED = """
UPDATE fd.cases SET reopen_prompt_posted_at = now()
WHERE id = %s AND reopen_prompt_posted_at IS NULL
"""


REOPEN_PROMPTS_PENDING = """
SELECT id FROM fd.cases
WHERE reporter_replied_at IS NOT NULL AND reopen_prompt_posted_at IS NULL
ORDER BY reporter_replied_at LIMIT 50
"""


HAS_UNMIRRORED_CONTENT = """
coalesce(btrim(m.body), '') <> '' OR EXISTS (
    SELECT 1 FROM fd.intake_message_files mf
    JOIN fd.intake_files f ON f.id = mf.file_id
    WHERE mf.message_id = m.id AND mf.mirrored_at IS NULL AND NOT mf.forwarded
      AND f.fetch_state IN ('pending', 'stored')
) OR EXISTS (
    SELECT 1 FROM fd.intake_shares s WHERE s.message_id = m.id AND s.kind = 'forward'
)
"""

NOT_CARD_MESSAGE = """
m.id <> (
    SELECT first_inbound.id FROM fd.intake_messages first_inbound
    WHERE first_inbound.conversation_id = c.id AND first_inbound.direction = 'inbound'
    ORDER BY first_inbound.posted_at, first_inbound.id
    LIMIT 1
)
"""

FOLLOW_UPS_WAITING = f"""
SELECT m.id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE r.case_id = %s AND m.direction = 'inbound' AND m.mirrored_ts IS NULL
  AND m.deleted_at IS NULL AND c.handed_off_at IS NOT NULL
  AND {NOT_CARD_MESSAGE} AND ({HAS_UNMIRRORED_CONTENT})
ORDER BY m.posted_at, m.id
"""


FOLLOW_UPS_ANYWHERE = f"""
SELECT DISTINCT r.case_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE m.direction = 'inbound' AND m.mirrored_ts IS NULL AND m.deleted_at IS NULL
  AND c.handed_off_at IS NOT NULL AND {NOT_CARD_MESSAGE}
  AND ({HAS_UNMIRRORED_CONTENT})
LIMIT 100
"""


FILES_WAITING = """
SELECT DISTINCT r.case_id
FROM fd.intake_message_files mf
JOIN fd.intake_files f ON f.id = mf.file_id
JOIN fd.intake_messages m ON m.id = mf.message_id
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE mf.mirrored_at IS NULL AND f.fetch_state = 'stored' AND NOT mf.forwarded
  AND m.direction = 'inbound' AND r.forwarded_ts IS NOT NULL
LIMIT 50
"""

FILES_ON_CASE = """
SELECT DISTINCT mf.message_id, r.forwarded_ts, r.is_anonymous, r.reporter_user_id,
       r.card_channel_id
FROM fd.intake_message_files mf
JOIN fd.intake_files f ON f.id = mf.file_id
JOIN fd.intake_messages m ON m.id = mf.message_id
JOIN fd.intake_conversations c ON c.id = m.conversation_id
JOIN fd.case_reports r ON r.id = c.report_id
WHERE r.case_id = %s AND mf.mirrored_at IS NULL AND f.fetch_state = 'stored'
  AND NOT mf.forwarded AND m.direction = 'inbound' AND r.forwarded_ts IS NOT NULL
ORDER BY mf.message_id
"""


def waiting_files(conn):
    return [row[0] for row in conn.execute(FILES_WAITING).fetchall()]


def post_files(client, conn, case_id, channel_id=None):
    sent = 0
    for message_id, forwarded_ts, anonymous, reporter, stored in conn.execute(
        FILES_ON_CASE, (case_id,)
    ).fetchall():
        try:
            posted_ts = attachments.share(
                client, conn, message_id, channel_or_firehouse(stored, channel_id, conn), forwarded_ts,
                author_fields=reporter_author_fields(client, anonymous, reporter),
            )
        except Exception as failure:
            log.warning("nemo: message %s's file would not carry: %s", message_id, failure)
            continue
        if posted_ts:
            sent += 1
    return sent


def waiting_follow_ups(conn):
    return [row[0] for row in conn.execute(FOLLOW_UPS_ANYWHERE).fetchall()]


def reopen_prompts_pending(conn):
    return [row[0] for row in conn.execute(REOPEN_PROMPTS_PENDING).fetchall()]


def post_follow_ups(client, conn, case_id, channel_id=None):
    posted_count = 0
    for (message_id,) in conn.execute(FOLLOW_UPS_WAITING, (case_id,)).fetchall():
        try:
            posted_ts = post_follow_up(client, conn, message_id, channel_id)
        except Exception as failure:
            log.warning("nemo: message %s would not carry: %s", message_id, failure)
            continue
        if posted_ts:
            posted_count += 1
    return posted_count


def post_reopen_prompt(client, conn, case_id, channel_id=None):
    row = conn.execute(REOPEN_PROMPT_PENDING, (case_id,)).fetchone()
    if row is None:
        return None

    still_resolved = row[0]
    posted_ts = post_reopen_prompt_message(client, conn, case_id, channel_id) if still_resolved else None
    conn.execute(MARK_REOPEN_PROMPT_POSTED, (case_id,))
    return posted_ts


def post_reopen_prompt_message(client, conn, case_id, channel_id=None):
    case = fetch_case(conn, case_id)
    if case is None or not case["forwarded_ts"] or case.get("imported"):
        return None

    text = views.lines.reporter_replied(case_id)
    return client.chat_postMessage(
        channel=card_channel(case, channel_id, conn),
        thread_ts=case["forwarded_ts"],
        text=text,
        blocks=views.case_card.reopen_prompt_blocks(case_id, text),
        unfurl_links=False,
    )["ts"]


def post_outbox_reply(client, thread_ts, sent_by, body, signed, channel_id=None):
    target_channel_id = channel_id or firehouse_channel()
    if not target_channel_id:
        log.warning("nemo: a reply waits for nemo.firehouse_channel to be set")
        return None

    member_profile = profile.profile(client, sent_by)
    author_fields = {"username": member_profile["name"]}
    if member_profile["icon"]:
        author_fields["icon_url"] = member_profile["icon"]
    author_fields["metadata"] = {
        "event_type": "nemo_message",
        "event_payload": {"source_user_id": sent_by},
    }

    text = f"{answer.PREFIX}{views.report.escape_but_mentions(body)}"
    if not signed:
        text = f"{answer.ANON}{text}"

    try:
        sent = client.chat_postMessage(
            channel=target_channel_id,
            thread_ts=thread_ts,
            text=text,
            unfurl_links=False,
            unfurl_media=False,
            **author_fields,
        )
    except Exception as failure:
        log.warning("nemo: the thread did not hear about the reply: %s", failure)
        return None

    return target_channel_id, sent["ts"]


def mirror(client, conn, case_id, channel_id=None):
    card_channel_id = card_channel_for(conn, case_id, channel_id)
    mirrored_count = 0

    for chat_id, author, body, thread_ts in chat.waiting(conn, case_id):
        member_profile = profile.profile(client, author)
        author_fields = {"username": member_profile["name"]}
        if member_profile["icon"]:
            author_fields["icon_url"] = member_profile["icon"]
        author_fields["metadata"] = {
            "event_type": "nemo_message",
            "event_payload": {"source_user_id": author},
        }

        try:
            sent = client.chat_postMessage(
                channel=card_channel_id,
                thread_ts=thread_ts,
                text=views.report.escape_but_mentions(body),
                unfurl_links=False,
                unfurl_media=False,
                **author_fields,
            )
        except Exception as failure:
            log.warning("nemo: chat %s did not reach the thread: %s", chat_id, failure)
            continue

        chat.mirrored(conn, chat_id, sent["ts"])
        mirrored_count += 1

    if mirrored_count:
        log.info("nemo: carried %s message(s) into case %s's thread", mirrored_count, case_id)
    return mirrored_count


INSERT_THREAD_LOG = """
INSERT INTO fd.case_chat
    (case_id, author_user_id, blocks, channel_id, ts, mirrored_ts, mirrored_at, mirrored_as,
     source_app)
VALUES (%s, %s, %s, %s, %s, %s, now(), 'nemo', 'nemo')
RETURNING id
"""


def post_thread_log(client, conn, case_id, blocks, by, fallback_text, log_format):
    thread_ts = thread_for(conn, case_id)
    if thread_ts is None:
        log.info("nemo: case %s has no thread yet, the echo has nowhere to go", case_id)
        return None

    card_channel_id = card_channel_for(conn, case_id)
    member_profile = profile.profile(client, by)
    author_fields = {"username": member_profile["name"]}
    if member_profile["icon"]:
        author_fields["icon_url"] = member_profile["icon"]
    author_fields["metadata"] = {
        "event_type": "nemo_message",
        "event_payload": {"source_user_id": by},
    }

    try:
        sent = client.chat_postMessage(
            channel=card_channel_id,
            thread_ts=thread_ts,
            blocks=blocks,
            text=fallback_text,
            unfurl_links=False,
            unfurl_media=False,
            **author_fields,
        )
    except Exception as failure:
        log.warning(log_format, case_id, failure)
        return None

    conn.execute(INSERT_THREAD_LOG, (case_id, by, Jsonb(blocks), card_channel_id, sent["ts"], sent["ts"]))
    return sent["ts"]


CHANNEL_NAME = "SELECT name FROM raw.channel_dim WHERE channel_id = %s"


def channel_name(conn, channel_id):
    row = conn.execute(CHANNEL_NAME, (channel_id,)).fetchone()
    return row[0] if row else None


def post_action_log(client, conn, case_id, values, by):
    name = channel_name(conn, values["channel_id"]) if values.get("channel_id") else None
    blocks = views.action.log_blocks(values, by, channel_name=name)
    return post_thread_log(client, conn, case_id, blocks, by, views.action.label(values["type_key"]),
        "nemo: the action log for case %s did not reach the thread: %s")


def post_resolution_log(client, conn, case_id, resolution, member_note, by, actions=()):
    blocks = views.resolve.log_blocks(resolution, member_note, by, actions, case_id)
    return post_thread_log(client, conn, case_id, blocks, by, views.resolve.label(resolution),
        "nemo: the resolution log for case %s did not reach the thread: %s")
