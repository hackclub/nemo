import logging

from bot.core import audit, blobs, outbox, parse, session
from bot.nemo import answer, carry, channel

log = logging.getLogger("bot.nemo")

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

LINKED = """
SELECT 1 FROM fd.staff_slack WHERE staff_user_id = %s AND revoked_at IS NULL
"""


class Desk:
    def __init__(self, client=None):
        self.client = client

    def redraw(self, case_id):
        with session() as conn:
            return channel.redraw(self.client, conn, case_id)

    def caught_up(self, case_id):
        drawn = None
        for name, work in (
            ("redraw", channel.redraw),
            ("wake", channel.tell_the_wake),
            ("follow-ups", channel.carry_follow_ups),
            ("files", channel.carry_files),
        ):
            try:
                with session() as conn:
                    done = work(self.client, conn, case_id)
                if name == "redraw":
                    drawn = done
            except Exception:
                log.exception("nemo: case %s could not have its %s seen to", case_id, name)
        return drawn

    def mirror(self, case_id):
        with session() as conn:
            return channel.mirror(self.client, conn, case_id)

    def mark(self, at, emoji):
        if at is None:
            return
        channel_id, ts = at
        try:
            self.client.reactions_add(channel=channel_id, timestamp=ts, name=emoji)
        except Exception as failure:
            log.warning("nemo: could not mark %s with %s: %s", ts, emoji, failure)

    def refuse(self, at, sent_by, said):
        self.mark(at, answer.STUCK)
        if at is None:
            return None
        channel_id, ts = at
        try:
            self.client.chat_postEphemeral(
                channel=channel_id, user=sent_by, thread_ts=ts, text=said
            )
        except Exception as failure:
            log.warning("nemo: could not say why it did not send: %s", failure)
        return None

    def answered(self, thread_ts, text, sent_by, signed=True, files=(), at=None):
        if not (text or "").strip() and not files:
            return None

        with session() as conn:
            row = conn.execute(WHO_TO_REACH, (thread_ts,)).fetchone()
        if not row:
            log.info("nemo: thread %s is not a report thread", thread_ts)
            return None
        conversation_id, _channel_id, _member_thread_ts, closed_at, report_id = row
        if closed_at:
            log.info("nemo: conversation %s is closed, not queueing", conversation_id)
            return self.refuse(
                at, sent_by, f"conversation {conversation_id} is closed, so nothing was sent"
            )

        with session() as conn:
            kept = self.keep_outgoing(conn, files)
            queued_id = outbox.queue(
                conn,
                conversation_id,
                "reply",
                text,
                sent_by,
                mode="signed" if signed else "body",
                files=kept,
                asked_in=at[0] if at else None,
                asked_at=at[1] if at else None,
            )
            outbox.claim_echo(conn, queued_id)
            outbox.echoed(conn, queued_id, None, "user")
            if report_id:
                conn.execute(FIRST_ANSWER, (report_id,))
                audit.record(
                    conn,
                    "report",
                    report_id,
                    "answered",
                    sent_by,
                    after={"mode": "signed" if signed else "body", "source": "nemo"},
                )

        log.info(
            "nemo: queued a %s answer for conversation %s as outbox %s",
            "signed" if signed else "unsigned", conversation_id, queued_id,
        )
        return queued_id

    def keep_outgoing(self, conn, files):
        kept = []
        for item in files or []:
            url = item.get("url_private_download") or item.get("url_private")
            name = item.get("name") or item.get("id") or "file"
            if not url:
                continue
            body = carry.fetch(url, self.client.token, blobs.cap())
            if body is None:
                log.warning("nemo: %s could not be kept, it is not going out", name)
                continue
            kept.append({
                "name": name,
                "mimetype": item.get("mimetype"),
                "original_w": parse.whole(item.get("original_w")),
                "original_h": parse.whole(item.get("original_h")),
                "sha256": blobs.stash(conn, body, item.get("mimetype")),
            })
        return kept

    def echo_queued(self, case_id=None):
        with session() as conn:
            rows = outbox.to_echo(conn, case_id)

        done = 0
        for outbox_id, body, mode, requested_by, forwarded_ts in rows:
            with session() as conn:
                if not outbox.claim_echo(conn, outbox_id):
                    continue
                if requested_by and conn.execute(LINKED, (requested_by,)).fetchone():
                    outbox.echoed(conn, outbox_id, None, "user")
                    continue
                at = channel.echo(
                    self.client, forwarded_ts, requested_by, body, mode == "signed",
                    channel.card_room(conn, case_id),
                )
                if at is None:
                    outbox.drop_echo(conn, outbox_id)
                    continue
                outbox.echoed(conn, outbox_id, at[1], "nemo")
                done += 1

        if done:
            log.info("nemo: echoed %s queued message(s) into the firehouse", done)
        return done

    def tick_queued(self):
        with session() as conn:
            waiting = outbox.to_tick(conn)

        for outbox_id, channel_id, ts, failed_at, error in waiting:
            room = channel_id or channel.firehouse_channel()
            self.mark((room, ts), answer.STUCK if failed_at else answer.SENT)
            if failed_at:
                self.tell_them_why(room, ts, error)
            with session() as conn:
                outbox.ticked(conn, outbox_id)

        return len(waiting)

    def tell_them_why(self, channel_id, ts, error):
        try:
            self.client.chat_postMessage(
                channel=channel_id,
                thread_ts=ts,
                text=f":x: that did not reach them: {error or 'shroud could not send it'}",
                unfurl_links=False,
            )
        except Exception as failure:
            log.warning("nemo: could not say why %s did not go: %s", ts, failure)
