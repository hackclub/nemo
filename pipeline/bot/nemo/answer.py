PREFIX = "?"
ANON = "~"

SENT = "white_check_mark"
STUCK = "x"


def read(text):
    said = (text or "").lstrip()
    anon = said.startswith(ANON) and said[1:2] == PREFIX
    if anon:
        said = said[1:].lstrip()
    if not said.startswith(PREFIX):
        return None

    return {"said": said[len(PREFIX):].lstrip(), "signed": not anon}


def meant_for_them(text):
    aimed = read(text)
    return None if aimed is None else aimed["said"]
