import logging

from bot.engine import case, intake, session
from bot.engine.whoami import bot_user_id
from bot.nemo import channel
from bot.nemo.cards import report as cards

log = logging.getLogger("bot.relay")

WHO_TO_REACH = """
SELECT c.id, c.channel_id, c.thread_ts, c.closed_at
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
WHERE m.mirrored_ts = %s
"""


class Relay:
    def __init__(self, shroud_client=None, nemo_client=None):
        self.shroud_client = shroud_client
        self.nemo_client = nemo_client

    def taken(self, conversation_id, message_id, anonymous=True):
        opener = bot_user_id(self.nemo_client, "nemo") if self.nemo_client else None
        with session() as conn:
            already = case.existing(conn, conversation_id)
            case_id = case.open_case(conn, conversation_id, opener, anonymous)
        log.info("relay: conversation %s is case %s", conversation_id, case_id)

        if self.nemo_client is None:
            log.warning(
                "relay: nemo is not running, case %s is recorded but not posted", case_id
            )
            return case_id

        with session() as conn:
            if already:
                channel.post_follow_up(self.nemo_client, conn, message_id)
            else:
                channel.post_report(self.nemo_client, conn, case_id)

        return case_id

    def answered(self, thread_ts, text, sent_by):
        if self.shroud_client is None:
            log.warning("relay: shroud is not running, cannot answer thread %s", thread_ts)
            return None
        if not (text or "").strip():
            return None

        with session() as conn:
            row = conn.execute(WHO_TO_REACH, (thread_ts,)).fetchone()
        if not row:
            log.info("relay: thread %s is not a report thread", thread_ts)
            return None
        conversation_id, channel_id, member_thread_ts, closed_at = row
        if closed_at:
            log.info("relay: conversation %s is closed, not delivering", conversation_id)
            return None

        said = cards.to_member(text)
        sent = self.shroud_client.chat_postMessage(
            channel=channel_id,
            thread_ts=member_thread_ts,
            text=said,
            unfurl_links=False,
            unfurl_media=False,
        )
        with session() as conn:
            intake.record(
                conn,
                {
                    "channel": channel_id,
                    "ts": sent["ts"],
                    "thread_ts": member_thread_ts,
                    "text": said,
                },
                direction="outbound",
                sent_by=sent_by,
            )
        log.info("relay: carried an answer to conversation %s", conversation_id)
        return sent["ts"]
