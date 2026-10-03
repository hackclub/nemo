PREFIX = "?"
ANON = "~"

SENT = "white_check_mark"
STUCK = "x"


def read(text):
    text = (text or "").lstrip()
    anon = text.startswith(ANON) and text[1:2] == PREFIX
    if anon:
        text = text[1:].lstrip()
    if not text.startswith(PREFIX):
        return None

    return {"body": text[len(PREFIX):].lstrip(), "signed": not anon}


def meant_for_them(text):
    aimed = read(text)
    return None if aimed is None else aimed["body"]
