ANONYMOUSLY = "sent anonymously"

GOT_IT = "white_check_mark"

NEMO_QUIET_AFTER = "5 minutes"

CATCHING_UP = (
    "The team's tools are catching up, so this may take a little longer to reach them. "
    "It is saved — there is no need to send it again."
)

DID_NOT_TAKE = (
    ":warning: That did not go through, so the Fire Department has not got it. "
    "Please try again in a few minutes."
)

NEMO_STANDING = """
SELECT bool_or(beat_at > now() - %s::interval)
FROM raw.worker_heartbeat
WHERE worker LIKE 'bot%%' AND worker LIKE '%%nemo%%'
"""


def nemo_is_behind(conn):
    try:
        row = conn.execute(NEMO_STANDING, (NEMO_QUIET_AFTER,)).fetchone()
    except Exception:
        return False
    return row is None or not row[0]


SUBMITTED = (
    "This report has been submitted. We've received your report and should get "
    "back to you within a couple hours."
)


def receipt_text(case_id):
    return SUBMITTED


def receipt(case_id, anonymous, behind=False):
    said = receipt_text(case_id)
    blocks = [{"type": "section", "text": {"type": "mrkdwn", "text": said}}]
    notes = []
    if anonymous:
        notes.append(ANONYMOUSLY)
    if behind:
        notes.append(CATCHING_UP)
    if notes:
        blocks.append(
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": note} for note in notes],
            }
        )
    return said, blocks


def not_taken():
    return DID_NOT_TAKE, [
        {"type": "section", "text": {"type": "mrkdwn", "text": DID_NOT_TAKE}}
    ]
