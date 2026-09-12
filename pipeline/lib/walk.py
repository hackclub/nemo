SHORT_AT = 0.9
NO_FLOOR = None

COMPLETE = "complete"
SHORT = "short"
UNVERIFIED = "unverified"


class WalkWrong(RuntimeError):
    """The walk did not read what the endpoint said was there"""


def check_walk(what, seen, expected, page_size, short_at=SHORT_AT):
    if short_at is not NO_FLOOR and short_at <= 0:
        raise ValueError(
            f"{what}: short_at={short_at} leaves no floor, so no walk can ever read short. "
            "Pass a fraction above 0, or pass walk.NO_FLOOR to say the endpoint has no usable count"
        )

    if expected is None:
        return None

    if seen > expected + page_size:
        raise WalkWrong(
            f"{what}: walked {seen} rows against a num_found of {expected}, "
            "refusing to commit"
        )

    if short_at is NO_FLOOR:
        return UNVERIFIED

    floor = int(expected * short_at)
    if expected > 0 and seen < floor:
        print(f"{what}: walked {seen} rows against a num_found of {expected}, under the {floor} floor, short")
        return SHORT

    return COMPLETE


def should_prune(verdict):
    return verdict == COMPLETE


def window_totals(counted, window):
    landed, held = 0, 0
    for start, stop, rows in counted:
        if (start, stop) == window:
            landed = rows
        else:
            held = max(held, rows)
    return landed, held


def covers_what_it_replaces(landed, held, floor=SHORT_AT):
    return landed >= int(held * floor)
