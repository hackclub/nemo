import logging

from bot.engine import case, intake, session
from bot.nemo import answer
from bot.engine.whoami import bot_user_id
from bot.nemo import channel
from bot.nemo import files as carry
from bot.nemo.cards import report as cards

log = logging.getLogger("bot.relay")

WHO_TO_REACH = """
SELECT c.id, c.channel_id, c.thread_ts, c.closed_at, c.report_id
FROM fd.intake_messages m
JOIN fd.intake_conversations c ON c.id = m.conversation_id
WHERE m.mirrored_ts = %s
"""

FIRST_ANSWER = """
UPDATE fd.case_reports SET first_replied_at = now()
WHERE id = %s AND first_replied_at IS NULL
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

    def mark(self, at, emoji):
        if at is None or self.nemo_client is None:
            return
        channel_id, ts = at
        try:
            self.nemo_client.reactions_add(channel=channel_id, timestamp=ts, name=emoji)
        except Exception as failure:
            log.warning("relay: could not mark %s with %s: %s", ts, emoji, failure)

    def refuse(self, at, sent_by, said):
        self.mark(at, answer.STUCK)
        if at is None or self.nemo_client is None:
            return None
        channel_id, ts = at
        try:
            self.nemo_client.chat_postEphemeral(
                channel=channel_id, user=sent_by, thread_ts=ts, text=said
            )
        except Exception as failure:
            log.warning("relay: could not say why it did not send: %s", failure)
        return None

    def answered(self, thread_ts, text, sent_by, files=(), at=None):
        if self.shroud_client is None:
            log.warning("relay: shroud is not running, cannot answer thread %s", thread_ts)
            return self.refuse(at, sent_by, "shroud is not running, so nothing was sent")
        if not (text or "").strip() and not files:
            return None

        with session() as conn:
            row = conn.execute(WHO_TO_REACH, (thread_ts,)).fetchone()
        if not row:
            log.info("relay: thread %s is not a report thread", thread_ts)
            return None
        conversation_id, channel_id, member_thread_ts, closed_at, report_id = row
        if closed_at:
            log.info("relay: conversation %s is closed, not delivering", conversation_id)
            return self.refuse(
                at, sent_by, f"conversation {conversation_id} is closed, so nothing was sent"
            )

        said = cards.to_member(text)
        try:
            sent = self.shroud_client.chat_postMessage(
                channel=channel_id,
                thread_ts=member_thread_ts,
                text=said,
                unfurl_links=False,
                unfurl_media=False,
            )
        except Exception as failure:
            log.warning("relay: could not reach conversation %s: %s", conversation_id, failure)
            return self.refuse(at, sent_by, f"slack refused it: {failure}")

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
            if report_id:
                conn.execute(FIRST_ANSWER, (report_id,))

        if files:
            carry.to_member(
                self.nemo_client, self.shroud_client, files, channel_id, member_thread_ts
            )

        self.mark(at, answer.SENT)
        log.info("relay: carried an answer to conversation %s", conversation_id)
        return sent["ts"]
