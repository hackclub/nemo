FIRST = (
    "Got it. The Fire Department has this, and someone will pick it up.\n"
    "Keep replying here if there is more, including screenshots and links."
)

AGAIN = "Added to what you sent. Nothing else you need to do."

ANONYMOUSLY = "sent anonymously"


def acknowledgement(first):
    return FIRST if first else AGAIN


def receipt_text(case_id):
    if case_id:
        return f"The Fire Department has your report. It is case {case_id}."
    return "The Fire Department has your report."


def receipt(case_id, anonymous):
    said = receipt_text(case_id)
    blocks = [{"type": "section", "text": {"type": "mrkdwn", "text": said}}]
    if anonymous:
        blocks.append(
            {
                "type": "context",
                "elements": [{"type": "mrkdwn", "text": ANONYMOUSLY}],
            }
        )
    return said, blocks
