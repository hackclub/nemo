FIRST = (
    "Got it. The Fire Department has this, and someone will pick it up.\n"
    "Keep replying here if there is more, including screenshots and links."
)

AGAIN = "Added to what you sent. Nothing else you need to do."


def acknowledgement(first):
    return FIRST if first else AGAIN
