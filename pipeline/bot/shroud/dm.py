import logging

from bot.engine import intake, session
from bot.shroud import consent, files
from bot.shroud.reply import acknowledgement, receipt

log = logging.getLogger("bot.shroud")

CARRIES_CONTENT = (None, "file_share", "me_message", "thread_broadcast")

INBOUND_SO_FAR = """
SELECT count(*) = 1
FROM fd.intake_messages
WHERE conversation_id = %s AND direction = 'inbound'
"""

STANDING = """
SELECT c.handed_off_at IS NOT NULL,
       (SELECT m.ts FROM fd.intake_messages m
        WHERE m.conversation_id = c.id AND m.direction = 'outbound'
          AND m.subtype = %s AND m.deleted_at IS NULL
        ORDER BY m.posted_at DESC LIMIT 1)
FROM fd.intake_conversations c
WHERE c.id = %s
"""

WHAT_THEY_SAID = """
SELECT body
FROM fd.intake_messages
WHERE conversation_id = %s AND direction = 'inbound' AND deleted_at IS NULL
ORDER BY posted_at, id
"""

HOW_MANY_FILES = """
SELECT count(*)
FROM fd.intake_message_files f
JOIN fd.intake_messages m ON m.id = f.message_id
WHERE m.conversation_id = %s
"""

CONVERSATION_OF = """
SELECT conversation_id FROM fd.intake_messages WHERE channel_id = %s AND ts = %s
"""

NEWEST_INBOUND = """
SELECT id FROM fd.intake_messages
WHERE conversation_id = %s AND direction = 'inbound'
ORDER BY posted_at DESC, id DESC LIMIT 1
"""

RETIRE_PROMPT = """
UPDATE fd.intake_messages SET subtype = %s, last_seen_at = now()
WHERE channel_id = %s AND ts = %s
"""


def preview(conn, conversation_id):
    bodies = [row[0] for row in conn.execute(WHAT_THEY_SAID, (conversation_id,)).fetchall()]
    held = conn.execute(HOW_MANY_FILES, (conversation_id,)).fetchone()[0]
    return consent.blocks(bodies, held)


def register(app, on_taken=None):
    @app.event("message")
    def on_message(event, client):
        if event.get("channel_type") != "im":
            return

        subtype = event.get("subtype")
        if subtype == "message_changed":
            return on_changed(event, client)
        if subtype == "message_deleted":
            return on_deleted(event)
        if subtype not in CARRIES_CONTENT:
            return
        if event.get("bot_id"):
            return

        thread_ts = intake.root_ts(event)

        with session() as conn:
            message_id, fresh = intake.record(conn, event)
            conversation_id = intake.conversation(conn, event["channel"], thread_ts)
            handed_off, prompt_ts = conn.execute(
                STANDING, (consent.SUBTYPE, conversation_id)
            ).fetchone()
            first = conn.execute(INBOUND_SO_FAR, (conversation_id,)).fetchone()[0]
            asking = None if handed_off else preview(conn, conversation_id)

        if not fresh:
            return
        log.info(
            "shroud: took message %s in %s thread %s", message_id, event["channel"], thread_ts
        )

        if event.get("files"):
            try:
                files.drain(client.token)
            except Exception:
                log.exception("shroud: could not keep the files, they stay pending")

        if handed_off:
            answer(client, event["channel"], thread_ts, acknowledgement(first))
            if on_taken:
                on_taken(conversation_id, message_id)
            return

        ask(client, event["channel"], thread_ts, prompt_ts, asking)

    def ask(client, channel_id, thread_ts, prompt_ts, blocks):
        if prompt_ts:
            client.chat_update(
                channel=channel_id, ts=prompt_ts, text=consent.FALLBACK, blocks=blocks
            )
            return

        sent = client.chat_postMessage(
            channel=channel_id,
            thread_ts=thread_ts,
            text=consent.FALLBACK,
            blocks=blocks,
        )
        with session() as conn:
            intake.record(
                conn,
                {
                    "channel": channel_id,
                    "ts": sent["ts"],
                    "thread_ts": thread_ts,
                    "text": consent.FALLBACK,
                    "blocks": blocks,
                    "subtype": consent.SUBTYPE,
                },
                direction="outbound",
            )

    def answer(client, channel_id, thread_ts, said):
        sent = client.chat_postMessage(channel=channel_id, thread_ts=thread_ts, text=said)
        with session() as conn:
            intake.record(
                conn,
                {
                    "channel": channel_id,
                    "ts": sent["ts"],
                    "thread_ts": thread_ts,
                    "text": said,
                },
                direction="outbound",
            )

    @app.action(consent.ACTION)
    def on_pick(ack):
        ack()

    @app.action(consent.CONFIRM)
    def on_confirm(ack, body, client):
        ack()
        channel_id = body["channel"]["id"]
        prompt_ts = body["message"]["ts"]
        anonymous = consent.chosen(body.get("state")) == consent.ANONYMOUS

        with session() as conn:
            row = conn.execute(CONVERSATION_OF, (channel_id, prompt_ts)).fetchone()
            if not row:
                return
            conversation_id = row[0]
            handed_off = conn.execute(
                STANDING, (consent.SUBTYPE, conversation_id)
            ).fetchone()[0]
            message_id = conn.execute(NEWEST_INBOUND, (conversation_id,)).fetchone()[0]

        if handed_off:
            client.chat_update(
                channel=channel_id, ts=prompt_ts, text=consent.ALREADY, blocks=[]
            )
            return

        with session() as conn:
            conn.execute(RETIRE_PROMPT, (consent.DONE, channel_id, prompt_ts))

        log.info(
            "shroud: conversation %s handed over, anonymous=%s", conversation_id, anonymous
        )
        case_id = on_taken(conversation_id, message_id, anonymous) if on_taken else None

        said, blocks = receipt(case_id, anonymous)
        client.chat_update(channel=channel_id, ts=prompt_ts, text=said, blocks=blocks)

    @app.action(consent.CANCEL)
    def on_cancel(ack, body, client):
        ack()
        channel_id = body["channel"]["id"]
        prompt_ts = body["message"]["ts"]

        with session() as conn:
            conn.execute(RETIRE_PROMPT, (consent.DONE, channel_id, prompt_ts))

        client.chat_update(
            channel=channel_id, ts=prompt_ts, text=consent.DROPPED, blocks=[]
        )

    def on_changed(event, client):
        message = event.get("message") or {}
        if not message.get("ts"):
            return
        with session() as conn:
            changed = intake.edit(conn, event["channel"], message)
            if not changed:
                return
            conversation_id = conn.execute(
                CONVERSATION_OF, (event["channel"], message["ts"])
            ).fetchone()[0]
            handed_off, prompt_ts = conn.execute(
                STANDING, (consent.SUBTYPE, conversation_id)
            ).fetchone()
            asking = None if handed_off else preview(conn, conversation_id)

        log.info("shroud: message %s was edited", changed)
        if prompt_ts and asking:
            client.chat_update(
                channel=event["channel"], ts=prompt_ts, text=consent.FALLBACK, blocks=asking
            )

    def on_deleted(event):
        if not event.get("deleted_ts"):
            return
        with session() as conn:
            gone = intake.delete(conn, event["channel"], event["deleted_ts"])
        if gone:
            log.info("shroud: message %s was deleted", gone)
