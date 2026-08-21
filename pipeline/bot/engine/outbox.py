GIVE_UP_AFTER = 3

WAITING = """
SELECT o.id, o.conversation_id, o.kind, o.body, o.mode, o.requested_by, o.attempts,
       c.channel_id, c.thread_ts, c.closed_at
FROM fd.intake_outbox o
JOIN fd.intake_conversations c ON c.id = o.conversation_id
WHERE o.sent_at IS NULL AND o.failed_at IS NULL
"""

BY_CONVERSATION = " AND o.conversation_id = %s"
ORDER = " ORDER BY o.requested_at LIMIT 20"

ANY_WAITING = """
SELECT DISTINCT conversation_id FROM fd.intake_outbox
WHERE sent_at IS NULL AND failed_at IS NULL
LIMIT 50
"""

SENT = """
UPDATE fd.intake_outbox SET sent_at = now(), message_id = %s, attempts = attempts + 1
WHERE id = %s AND sent_at IS NULL
"""

TRIED = """
UPDATE fd.intake_outbox SET attempts = attempts + 1 WHERE id = %s
"""

CLAIM_ECHO = """
UPDATE fd.intake_outbox SET echoed_at = now()
WHERE id = %s AND echoed_at IS NULL
RETURNING id
"""

ECHOED = """
UPDATE fd.intake_outbox SET echoed_ts = %s, echoed_as = %s WHERE id = %s
"""

DROP_ECHO = """
UPDATE fd.intake_outbox SET echoed_at = NULL WHERE id = %s AND echoed_ts IS NULL
"""

UNTICKED = """
SELECT id, echoed_ts FROM fd.intake_outbox
WHERE echoed_ts IS NOT NULL AND ticked_at IS NULL
"""

BY_CONVO = " AND conversation_id = %s"
TICK_ORDER = " ORDER BY echoed_at LIMIT 20"

TICKED = """
UPDATE fd.intake_outbox SET ticked_at = now() WHERE id = %s
"""

GAVE_UP = """
UPDATE fd.intake_outbox
SET attempts = attempts + 1, failed_at = now(), error = %s
WHERE id = %s AND sent_at IS NULL
"""


class Queued:
    def __init__(self, row):
        (
            self.id,
            self.conversation_id,
            self.kind,
            self.body,
            self.mode,
            self.requested_by,
            self.attempts,
            self.channel_id,
            self.thread_ts,
            self.closed_at,
        ) = row

    @property
    def last_try(self):
        return self.attempts + 1 >= GIVE_UP_AFTER


def waiting(conn, conversation_id=None):
    if conversation_id is None:
        rows = conn.execute(WAITING + ORDER).fetchall()
    else:
        rows = conn.execute(WAITING + BY_CONVERSATION + ORDER, (conversation_id,)).fetchall()
    return [Queued(row) for row in rows]


def any_waiting(conn):
    return [row[0] for row in conn.execute(ANY_WAITING).fetchall()]


def sent(conn, outbox_id, message_id):
    conn.execute(SENT, (message_id, outbox_id))


def unticked(conn, conversation_id=None):
    if conversation_id is None:
        return conn.execute(UNTICKED + TICK_ORDER).fetchall()

    return conn.execute(UNTICKED + BY_CONVO + TICK_ORDER, (conversation_id,)).fetchall()


def ticked(conn, outbox_id):
    conn.execute(TICKED, (outbox_id,))


def claim_echo(conn, outbox_id):
    return conn.execute(CLAIM_ECHO, (outbox_id,)).fetchone() is not None


def echoed(conn, outbox_id, ts, how):
    conn.execute(ECHOED, (ts, how, outbox_id))


def drop_echo(conn, outbox_id):
    conn.execute(DROP_ECHO, (outbox_id,))


def stumbled(conn, outbox_id, error, give_up):
    if give_up:
        conn.execute(GAVE_UP, (str(error)[:500], outbox_id))
    else:
        conn.execute(TRIED, (outbox_id,))
