import logging

from bot.engine import audit, case, evidence, intake, outbox, session
from bot.nemo import answer
from bot.engine.whoami import bot_user_id
from bot.nemo import channel, who
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

FIRST_ANSWER_FOR = """
UPDATE fd.case_reports SET first_replied_at = now()
WHERE id = (SELECT report_id FROM fd.intake_conversations WHERE id = %s)
  AND first_replied_at IS NULL
"""

LINKED = """
SELECT 1 FROM fd.staff_slack WHERE staff_user_id = %s AND revoked_at IS NULL
"""

THREAD_OF = """
SELECT r.forwarded_ts
FROM fd.intake_conversations c
JOIN fd.case_reports r ON r.id = c.report_id
WHERE c.id = %s AND r.forwarded_ts IS NOT NULL
"""


class Relay:
    def __init__(self, shroud_client=None, nemo_client=None):
        self.shroud_client = shroud_client
        self.nemo_client = nemo_client

    def taken(self, conversation_id, message_id, anonymous=True):
        opener = bot_user_id(self.nemo_client, "nemo") if self.nemo_client else None
        woke = None
        with session() as conn:
            already = case.existing(conn, conversation_id)
            case_id = case.open_case(conn, conversation_id, opener, anonymous)
            brought = evidence.promote(conn, case_id, conversation_id, opener)
            if already:
                woke = case.wake(conn, case_id, opener)
        log.info("relay: conversation %s is case %s", conversation_id, case_id)
        if brought["threads"] or brought["messages"]:
            log.info(
                "relay: case %s came with %s thread(s) and %s message(s)",
                case_id, brought["threads"], brought["messages"],
            )

        if self.nemo_client is None:
            log.warning(
                "relay: nemo is not running, case %s is recorded but not posted", case_id
            )
            return case_id

        with session() as conn:
            if already:
                channel.post_follow_up(self.nemo_client, conn, message_id)
                if woke:
                    log.info("relay: case %s was %s, they wrote back", case_id, woke)
                    channel.said_again(self.nemo_client, conn, case_id, woke)
            else:
                channel.post_report(self.nemo_client, conn, case_id)

        return case_id

    def redraw(self, case_id):
        if self.nemo_client is None:
            return None
        with session() as conn:
            return channel.redraw(self.nemo_client, conn, case_id)

    def mirror(self, case_id):
        if self.nemo_client is None:
            return None
        with session() as conn:
            return channel.mirror(self.nemo_client, conn, case_id)

    def deliver(self, conversation_id=None):
        if self.shroud_client is None:
            log.warning("relay: shroud is not running, the outbox waits")
            return 0

        with session() as conn:
            queue = outbox.waiting(conn, conversation_id)

        sent = 0
        for queued in queue:
            with session() as conn:
                if self.hand_over(conn, queued):
                    sent += 1

        if sent:
            log.info("relay: sent %s queued message(s)", sent)

        self.tick_echoes(conversation_id)
        return sent

    def tick_echoes(self, conversation_id=None):
        if self.nemo_client is None:
            return 0

        with session() as conn:
            waiting = outbox.unticked(conn, conversation_id)

        for outbox_id, ts in waiting:
            self.mark((channel.firehouse_channel(), ts), answer.SENT)
            with session() as conn:
                outbox.ticked(conn, outbox_id)

        return len(waiting)

    def hand_over(self, conn, queued):
        if queued.closed_at:
            outbox.stumbled(conn, queued.id, "the conversation is closed", True)
            log.info("relay: outbox %s is for a closed conversation", queued.id)
            return False

        signed = queued.mode == "signed"
        try:
            posted = self.shroud_client.chat_postMessage(
                channel=queued.channel_id,
                thread_ts=queued.thread_ts,
                text=cards.to_member(queued.body),
                unfurl_links=False,
                unfurl_media=False,
                **self.wearing(queued.requested_by, signed),
            )
        except Exception as failure:
            outbox.stumbled(conn, queued.id, failure, queued.last_try)
            log.warning("relay: outbox %s did not go: %s", queued.id, failure)
            return False

        message_id, _ = intake.record(
            conn,
            {
                "channel": queued.channel_id,
                "ts": posted["ts"],
                "thread_ts": queued.thread_ts,
                "text": cards.to_member(queued.body),
            },
            direction="outbound",
            sent_by=queued.requested_by,
        )
        outbox.sent(conn, queued.id, message_id)
        if queued.kind == "reply":
            conn.execute(FIRST_ANSWER_FOR, (queued.conversation_id,))
        self.tell_the_thread(conn, queued, signed)
        return True

    def wearing(self, user_id, signed):
        if not signed or not user_id or self.nemo_client is None:
            return {}

        seen = who.face(self.nemo_client, user_id)
        worn = {"username": seen["name"]}
        if seen["icon"]:
            worn["icon_url"] = seen["icon"]
        worn["metadata"] = {
            "event_type": "nemo_message",
            "event_payload": {"source_user_id": user_id},
        }
        return worn

    def tell_the_thread(self, conn, queued, signed):
        if self.nemo_client is None:
            return
        if conn.execute(LINKED, (queued.requested_by,)).fetchone():
            log.info("relay: outbox %s is theirs to echo, they linked slack", queued.id)
            return

        row = conn.execute(THREAD_OF, (queued.conversation_id,)).fetchone()
        if not row or not outbox.claim_echo(conn, queued.id):
            return

        at = channel.echo(self.nemo_client, row[0], queued.requested_by, queued.body, signed)
        if at is None:
            return outbox.drop_echo(conn, queued.id)

        outbox.echoed(conn, queued.id, at[1], "nemo")
        self.mark(at, answer.SENT)
        outbox.ticked(conn, queued.id)

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

    def answered(self, thread_ts, text, sent_by, signed=True, files=(), at=None):
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
                **self.wearing(sent_by, signed),
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
                audit.record(
                    conn,
                    "report",
                    report_id,
                    "answered",
                    sent_by,
                    after={"mode": "signed" if signed else "body", "source": "shroud"},
                )

        if files:
            carry.to_member(
                self.nemo_client, self.shroud_client, files, channel_id, member_thread_ts
            )

        self.mark(at, answer.SENT)
        log.info(
            "relay: carried a %s answer to conversation %s",
            "signed" if signed else "unsigned",
            conversation_id,
        )
        return sent["ts"]
