import logging

from bot.engine import intake, session
from bot.shroud import files
from bot.shroud.reply import acknowledgement

log = logging.getLogger("bot.shroud")

CARRIES_CONTENT = (None, "file_share", "me_message", "thread_broadcast")

INBOUND_SO_FAR = """
SELECT m.conversation_id, count(*) OVER (PARTITION BY m.conversation_id) = 1
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
WHERE c.channel_id = %s AND c.closed_at IS NULL AND m.direction = 'inbound'
LIMIT 1
"""


def register(app, on_taken=None):
    @app.event("message")
    def on_message(event, client):
        if event.get("channel_type") != "im":
            return

        subtype = event.get("subtype")
        if subtype == "message_changed":
            return on_changed(event)
        if subtype == "message_deleted":
            return on_deleted(event)
        if subtype not in CARRIES_CONTENT:
            return
        if event.get("bot_id"):
            return

        with session() as conn:
            message_id, fresh = intake.record(conn, event)
            row = conn.execute(INBOUND_SO_FAR, (event["channel"],)).fetchone()
            conversation_id, first = (row[0], row[1]) if row else (None, True)

        if not fresh:
            return
        log.info("shroud: took message %s in %s", message_id, event["channel"])

        if event.get("files"):
            try:
                files.drain(client.token)
            except Exception:
                log.exception("shroud: could not keep the files, they stay pending")

        sent = client.chat_postMessage(channel=event["channel"], text=acknowledgement(first))
        with session() as conn:
            intake.record(
                conn,
                {
                    "channel": event["channel"],
                    "ts": sent["ts"],
                    "text": acknowledgement(first),
                },
                direction="outbound",
            )

        if on_taken and conversation_id:
            on_taken(conversation_id, message_id)

    def on_changed(event):
        message = event.get("message") or {}
        if not message.get("ts"):
            return
        with session() as conn:
            changed = intake.edit(conn, event["channel"], message)
        if changed:
            log.info("shroud: message %s was edited", changed)

    def on_deleted(event):
        if not event.get("deleted_ts"):
            return
        with session() as conn:
            gone = intake.delete(conn, event["channel"], event["deleted_ts"])
        if gone:
            log.info("shroud: message %s was deleted", gone)
