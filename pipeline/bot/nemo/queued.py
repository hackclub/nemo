import logging

from bot.core import parse
from bot.nemo import cards
from bot.nemo.channel import ASSIGNEES, SUBJECTS, case_url

log = logging.getLogger("bot.nemo")

CASE = """
SELECT id, category_key, resolved_at, card_channel_id, card_ts, card_digest
FROM fd.cases WHERE id = %s
"""

KEPT = """
UPDATE fd.cases SET card_channel_id = %s, card_ts = %s, card_digest = %s, updated_at = now()
WHERE id = %s AND card_ts IS NULL
"""

REDRAWN = """
UPDATE fd.cases SET card_digest = %s, updated_at = now() WHERE id = %s
"""

LOST = """
UPDATE fd.cases SET card_channel_id = NULL, card_ts = NULL, card_digest = NULL WHERE id = %s
"""


def digest_of(blocks):
    return parse.digest(None, blocks, None)


def gather(conn, case_id):
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
        "url": case_url(row[0]),
    }
    case["subjects"] = [one[0] for one in conn.execute(SUBJECTS, (case_id,)).fetchall()]
    case["assignees"] = [one[0] for one in conn.execute(ASSIGNEES, (case_id,)).fetchall()]
    return case


def post(client, conn, case_id, channel_id, thread_ts):
    case = gather(conn, case_id)
    if case is None or case["card_ts"]:
        return case and case["card_ts"]

    built = cards.queued.blocks(case)
    sent = client.chat_postMessage(
        channel=channel_id,
        thread_ts=thread_ts,
        text=cards.queued.fallback(case),
        blocks=built,
        metadata=cards.queued.metadata(case),
        unfurl_links=False,
        unfurl_media=False,
    )
    conn.execute(KEPT, (channel_id, sent["ts"], digest_of(built), case_id))
    log.info("nemo: case %s has a card in %s", case_id, channel_id)
    return sent["ts"]


def redraw(client, conn, case_id, channel_id=None):
    case = gather(conn, case_id)
    if case is None or not case["card_ts"]:
        return None

    built = cards.queued.blocks(case)
    fingerprint = digest_of(built)
    if fingerprint == case["card_digest"]:
        return case["card_ts"]

    try:
        client.chat_update(
            channel=case["card_channel_id"],
            ts=case["card_ts"],
            text=cards.queued.fallback(case),
            blocks=built,
        )
    except Exception as failure:
        log.warning("nemo: case %s card could not be redrawn: %s", case_id, failure)
        conn.execute(LOST, (case_id,))
        return None

    conn.execute(REDRAWN, (fingerprint, case_id))
    return case["card_ts"]
