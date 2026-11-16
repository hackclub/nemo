import re

PREFIX = "?"
ANON = "~"
QUESTION_MARKS_ONLY = re.compile(r"[?\s]+")

SENT_REACTION = "white_check_mark"
FAILED_REACTION = "x"


def read(text):
    text = (text or "").lstrip()
    is_anonymous = text.startswith(ANON) and text[1:2] == PREFIX
    if is_anonymous:
        text = text[1:].lstrip()
    if not text.startswith(PREFIX):
        return None

    body = text[len(PREFIX):].lstrip()
    if QUESTION_MARKS_ONLY.fullmatch(body):
        return None
    return {"body": body, "signed": not is_anonymous}


def reply_body(text):
    parsed = read(text)
    return None if parsed is None else parsed["body"]
