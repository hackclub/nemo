PREFIX = "?"

SENT = "white_check_mark"
STUCK = "x"


def meant_for_them(text):
    said = (text or "").lstrip()
    if not said.startswith(PREFIX):
        return None
    return said[len(PREFIX):].lstrip()
