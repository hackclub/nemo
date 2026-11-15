import logging

from bot.nemo import card_facts, views
from bot.nemo.channel import (
    ASSIGNEES,
    SUBJECTS,
    card_mark,
    card_state,
    case_url,
    has_legacy_digest,
    firehouse_channel,
    is_foreign_message_error,
    mark_card,
    mark_root,
    author_display_fields,
    root_mark,
    thread_url,
    unfurl_opening,
)
from lyla import claim

log = logging.getLogger("bot.nemo")

CASE = """
SELECT id, category_key, resolved_at, card_channel_id, card_ts, card_digest, opened_by,
       resolution, card_thread_ts, card_header_ts, card_header_digest
FROM fd.cases WHERE id = %s
"""

OPENING = """
SELECT id, body FROM fd.case_chat
WHERE case_id = %s AND mirrored_as = 'card' AND deleted_at IS NULL
ORDER BY id LIMIT 1
"""

MARK_OPENING_MIRRORED = """
UPDATE fd.case_chat SET mirrored_ts = %s, mirrored_at = now(), last_seen_at = now()
WHERE id = %s AND mirrored_ts IS NULL
"""

ON_THREAD = """
SELECT id FROM fd.cases WHERE card_channel_id = %s AND card_thread_ts = %s LIMIT 1
"""

ON_REPORT_THREAD = """
SELECT case_id FROM fd.case_reports
WHERE card_channel_id = %s AND forwarded_ts = %s
ORDER BY id LIMIT 1
"""

CLAIM_CARD = """
SELECT card_ts FROM fd.cases WHERE id = %s FOR UPDATE
"""

CARD_MISSING = """
SELECT 1 FROM fd.cases c
WHERE c.id = %s AND c.card_ts IS NULL AND c.source_app <> 'lyla'
  AND NOT EXISTS (SELECT 1 FROM fd.case_reports r WHERE r.case_id = c.id)
"""

SET_CARD = """
UPDATE fd.cases SET card_channel_id = %s, card_thread_ts = %s, card_ts = %s,
                    card_digest = %s, card_header_digest = %s, updated_at = now()
WHERE id = %s AND card_ts IS NULL
"""

SET_CARD_DIGEST = """
UPDATE fd.cases SET card_digest = %s, updated_at = now() WHERE id = %s
"""



def case_for_root(conn, channel_id, thread_ts):
    row = conn.execute(ON_THREAD, (channel_id, thread_ts)).fetchone()
    return row[0] if row else None


def case_for_thread(conn, channel_id, thread_ts):
    case_id = case_for_root(conn, channel_id, thread_ts)
    if case_id is not None:
        return case_id
    row = conn.execute(ON_REPORT_THREAD, (channel_id, thread_ts)).fetchone()
    return row[0] if row else None


def mark_key(case, thread_ts):
    return f"root:{root_mark(case)}" if thread_ts else card_mark(case)


def mark(client, channel_id, thread_ts, ts, case, is_new=False):
    if thread_ts:
        return mark_root(client, channel_id, thread_ts, ts, case, is_new=is_new)
    return mark_card(client, channel_id, ts, case, is_new=is_new)


def fetch_case(conn, case_id):
    row = conn.execute(CASE, (case_id,)).fetchone()
    if row is None:
        return None

    case = {
        "case_id": row[0],
        "category_key": row[1],
        "resolved_at": row[2],
        "card_channel_id": row[3],
        "card_ts": row[4],
        "card_digest": row[5],
        "opened_by": row[6],
        "resolution": row[7],
        "card_thread_ts": row[8],
        "card_header_ts": row[9],
        "card_header_digest": row[10],
        "url": case_url(row[0]),
    }
    case["subjects"] = [one[0] for one in conn.execute(SUBJECTS, (case_id,)).fetchall()]
    case["assignees"] = [one[0] for one in conn.execute(ASSIGNEES, (case_id,)).fetchall()]
    case["mark_held"] = claim.waiting(conn, case_id)
    opening = conn.execute(OPENING, (case_id,)).fetchone()
    case["opening_id"], case["body"] = opening if opening else (None, None)
    if case["body"]:
        case["numbering"] = views.linked.numbering(case["body"], [], 1)
    return case


SET_HEADER_TS = """
UPDATE fd.cases SET card_header_ts = %s, card_header_digest = %s
WHERE id = %s AND card_header_ts IS NULL
"""

SET_HEADER_DIGEST = """
UPDATE fd.cases SET card_header_digest = %s WHERE id = %s
"""


def post_header(client, conn, case, channel_id, card_ts):
    if case.get("card_header_ts") or not views.queued.needs_header(case):
        return None
    card_facts.enrich(client, conn, case, case_url, thread_url)
    try:
        sent = client.chat_postMessage(
            channel=channel_id,
            thread_ts=card_ts,
            unfurl_links=False,
            unfurl_media=False,
            **views.case_card.render(case),
        )
    except Exception as failure:
        log.warning("nemo: case %s has no header in its thread: %s", case["case_id"], failure)
        return None
    conn.execute(SET_HEADER_TS, (sent["ts"], views.case_card.digest(case), case["case_id"]))
    return sent["ts"]


def sync_header(client, conn, case):
    extra = {}
    if views.queued.needs_header(case):
        if case["card_thread_ts"]:
            return None
        if not case.get("card_header_ts"):
            return post_header(client, conn, case, case["card_channel_id"], case["card_ts"])
        target_ts = case["card_header_ts"]
    else:
        target_ts = case["card_ts"]
        extra["metadata"] = views.queued.metadata(case)

    card_facts.enrich(client, conn, case, case_url, thread_url)
    digest = views.case_card.digest(case)
    if digest == case.get("card_header_digest"):
        return target_ts
    try:
        client.chat_update(channel=case["card_channel_id"], ts=target_ts, **extra,
                           **views.case_card.render(case))
    except Exception as failure:
        if not is_foreign_message_error(failure):
            raise
        log.warning("nemo: case %s keeps its header as it was, slack would not edit it: %s",
                    case["case_id"], failure)
    conn.execute(SET_HEADER_DIGEST, (digest, case["case_id"]))
    return target_ts


def post_thread_extras(client, conn, case, channel_id, card_ts):
    post_header(client, conn, case, channel_id, card_ts)
    unfurl_opening(client, conn, case["case_id"], channel_id, card_ts)


def author_fields(client, case):
    if not case["opening_id"] or not case["opened_by"]:
        return {}
    return author_display_fields(client, False, case["opened_by"])


def post(client, conn, case_id, channel_id, thread_ts=None):
    case = fetch_case(conn, case_id)
    if case is None or case["card_ts"]:
        return case and case["card_ts"]

    row = conn.execute(CLAIM_CARD, (case_id,)).fetchone()
    if row and row[0]:
        log.info("nemo: case %s went up while we were asking, leaving it", case_id)
        return row[0]

    if not views.queued.needs_header(case):
        card_facts.enrich(client, conn, case, case_url, thread_url)
    built = views.queued.build_blocks(case)
    sent = client.chat_postMessage(
        channel=channel_id,
        thread_ts=thread_ts,
        text=views.queued.fallback(case),
        blocks=built,
        metadata=views.queued.metadata(case),
        unfurl_links=False,
        unfurl_media=False,
        **author_fields(client, case),
    )
    conn.execute(
        SET_CARD,
        (channel_id, thread_ts, sent["ts"], card_state(mark_key(case, thread_ts)),
         None if views.queued.needs_header(case) else views.case_card.digest(case), case_id),
    )
    mark(client, channel_id, thread_ts, sent["ts"], case, is_new=True)
    if not thread_ts:
        post_thread_extras(client, conn, case, channel_id, sent["ts"])
    if case["opening_id"]:
        conn.execute(MARK_OPENING_MIRRORED, (sent["ts"], case["opening_id"]))
    log.info("nemo: case %s has a card in %s", case_id, channel_id)
    return sent["ts"]


def refresh_card(client, conn, case_id, channel_id=None):
    case = fetch_case(conn, case_id)
    if case is None or not case["card_ts"]:
        return None

    state = card_state(mark_key(case, case["card_thread_ts"]))
    if state != case["card_digest"]:
        if has_legacy_digest(case["card_digest"]):
            try:
                client.chat_update(
                    channel=case["card_channel_id"],
                    ts=case["card_ts"],
                    text=views.queued.fallback(case),
                    blocks=views.queued.build_blocks(case),
                )
            except Exception as failure:
                log.warning("nemo: case %s keeps its card as it was, slack would not edit it: %s",
                            case_id, failure)
                if is_foreign_message_error(failure):
                    conn.execute(SET_CARD_DIGEST, (state, case_id))
                return case["card_ts"]

        conn.execute(SET_CARD_DIGEST, (state, case_id))
        mark(client, case["card_channel_id"], case["card_thread_ts"], case["card_ts"], case,
             is_new=case["card_digest"] == card_state(None))
        if not case["card_thread_ts"]:
            unfurl_opening(client, conn, case["case_id"], case["card_channel_id"], case["card_ts"])

    sync_header(client, conn, case)
    return case["card_ts"]


def post_missing_card(client, conn, case_id, channel_id=None):
    if conn.execute(CARD_MISSING, (case_id,)).fetchone() is None:
        return None

    card_channel_id = channel_id or firehouse_channel(conn)
    if not card_channel_id:
        log.warning("nemo: case %s waits for nemo.firehouse_channel to be set", case_id)
        return None

    return post(client, conn, case_id, card_channel_id)
