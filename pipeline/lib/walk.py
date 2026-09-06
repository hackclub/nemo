SHORT_AT = 0.9

COMPLETE = "complete"
SHORT = "short"


class WalkWrong(RuntimeError):
    """The walk did not read what the endpoint said was there"""


def check_walk(what, seen, expected, page_size, short_at=SHORT_AT):
    if expected is None:
        return None

    if seen > expected + page_size:
        raise WalkWrong(
            f"{what}: walked {seen} rows against a num_found of {expected}, "
            "refusing to commit"
        )

    floor = int(expected * short_at)
    if expected > 0 and seen < floor:
        print(f"{what}: walked {seen} rows against a num_found of {expected}, under the {floor} floor, short")
        return SHORT

    return COMPLETE


def should_prune(verdict):
    return verdict == COMPLETE
