import logging

from bot.nemo import card_facts, case_queue, channel, views

log = logging.getLogger("bot.nemo")

KEPT_PER_CASE = 5

INSERT = """
INSERT INTO fd.case_card_posts (case_id, channel_id, message_ts, digest, posted_by)
VALUES (%s, %s, %s, %s, %s)
"""

PRUNE = """
DELETE FROM fd.case_card_posts
WHERE case_id = %s
  AND id NOT IN (SELECT id FROM fd.case_card_posts WHERE case_id = %s ORDER BY id DESC LIMIT %s)
"""

POSTED = """
SELECT id, channel_id, message_ts, digest FROM fd.case_card_posts WHERE case_id = %s ORDER BY id
"""

SET_DIGEST = "UPDATE fd.case_card_posts SET digest = %s WHERE id = %s"

FORGET = "DELETE FROM fd.case_card_posts WHERE id = %s"


def load(client, conn, case_id):
    case = channel.fetch_case(conn, case_id) or case_queue.fetch_case(conn, case_id)
    if case is None:
        return None
    return card_facts.enrich(client, conn, case, channel.case_url, channel.thread_url)


def post(client, conn, case_id, channel_id, thread_ts, by=None):
    case = load(client, conn, case_id)
    if case is None:
        return None
    try:
        sent = client.chat_postMessage(
            channel=channel_id, thread_ts=thread_ts, unfurl_links=False, unfurl_media=False,
            **views.case_card.render(case),
        )
    except Exception as failure:
        log.warning("nemo: case %s card would not post in %s: %s", case_id, channel_id, failure)
        return None
    conn.execute(INSERT, (case_id, channel_id, sent["ts"], views.case_card.digest(case), by))
    conn.execute(PRUNE, (case_id, case_id, KEPT_PER_CASE))
    return sent["ts"]


def refresh(client, conn, case_id, channel_id=None):
    posted = conn.execute(POSTED, (case_id,)).fetchall()
    if not posted:
        return 0
    case = load(client, conn, case_id)
    if case is None:
        return 0

    digest = views.case_card.digest(case)
    rendered = views.case_card.render(case)
    updated = 0
    for post_id, post_channel_id, ts, stored in posted:
        if stored == digest:
            continue
        try:
            client.chat_update(channel=post_channel_id, ts=ts, **rendered)
        except Exception as failure:
            if not channel.is_foreign_message_error(failure):
                raise
            log.info("nemo: case %s card at %s is gone, forgetting it: %s", case_id, ts, failure)
            conn.execute(FORGET, (post_id,))
            continue
        conn.execute(SET_DIGEST, (digest, post_id))
        updated += 1
    return updated
