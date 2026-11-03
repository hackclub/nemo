from lyla.mapping import LYLA_BOT_USER_ID

SKIP = "skip"
CHAT = "chat"

REPORT_FOR_THREAD = """
SELECT r.id FROM fd.case_reports r
WHERE r.card_channel_id = %s AND r.forwarded_ts = %s
ORDER BY r.id LIMIT 1
"""

KNOWN_MIRRORS = """
SELECT one.ts FROM unnest(%s::text[]) AS one(ts)
WHERE EXISTS (SELECT 1 FROM fd.intake_messages m WHERE m.mirrored_ts = one.ts)
   OR EXISTS (SELECT 1 FROM fd.intake_outbox o WHERE o.echoed_ts = one.ts)
   OR EXISTS (SELECT 1 FROM fd.case_chat c WHERE c.mirrored_ts = one.ts)
"""


def report_for_thread(conn, channel_id, thread_ts):
    row = conn.execute(REPORT_FOR_THREAD, (channel_id, thread_ts)).fetchone()
    return row[0] if row else None


def known_mirrors(conn, timestamps):
    if not timestamps:
        return set()
    return {row[0] for row in conn.execute(KNOWN_MIRRORS, (list(timestamps),)).fetchall()}


def classify(message, thread_ts, report_id, mirrors, own_ids=()):
    ts = message.get("ts")
    if not ts or not (message.get("text") or message.get("blocks") or message.get("files")):
        return SKIP
    if ts in mirrors:
        return SKIP
    if message.get("user") == LYLA_BOT_USER_ID:
        return SKIP
    if own_ids and (message.get("user") in own_ids or message.get("bot_id") in own_ids):
        return SKIP
    if report_id and ts == thread_ts:
        return SKIP
    return CHAT
