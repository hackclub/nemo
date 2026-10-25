def header(case_id, url=None):
    return f"<{url}|Case {case_id}>" if url else f"Case {case_id}"


def people(user_ids, actor=None):
    labels = ["themselves" if one == actor else f"<@{one}>" for one in user_ids]
    if len(labels) < 2:
        return "".join(labels)
    return ", ".join(labels[:-1]) + f" and {labels[-1]}"


def claimed(actor, case_id):
    return f"<@{actor}> claimed case {case_id}"


def assigned(actor, case_id, user_ids):
    other_ids = [one for one in user_ids if one != actor]
    lines = [claimed(actor, case_id)] if actor in user_ids else []
    if other_ids:
        lines.append(f"<@{actor}> assigned case {case_id} to {people(other_ids)}")
    return lines


def unassigned(actor, case_id, user_ids):
    return f"<@{actor}> unassigned {people(user_ids, actor)} from case {case_id}"


def number(case_id, url=None):
    return f"<{url}|{case_id}>" if url else str(case_id)


THIS_CASE = "(this case)"


def merged(actor, duplicate_ids, target_id, url_of=lambda case_id: None):
    target = number(target_id, url_of(target_id))
    numbers = [number(one, url_of(one)) for one in duplicate_ids]
    if len(numbers) == 1:
        listed = f"case {numbers[0]}"
    else:
        listed = "cases " + ", ".join(numbers[:-1]) + f" and {numbers[-1]}"
    entries = [(target_id, f"<@{actor}> merged {listed} into case {target} {THIS_CASE}")]
    for case_id, linked in zip(duplicate_ids, numbers):
        entries.append((case_id, f"<@{actor}> merged case {linked} {THIS_CASE} into case {target}"))
    return entries


def resolved(actor, case_id, label=None):
    line = f"<@{actor}> resolved case {case_id}"
    return f"{line}: {label}" if label else line


def reopened(actor, case_id):
    return f"<@{actor}> reopened case {case_id}"


def reporter_replied(case_id):
    return f"Reporter replied to resolved case {case_id}"


def reopened_by_reporter(case_id):
    return f"Case {case_id} reopened after the reporter replied"


def note_added(actor, body):
    return f"<@{actor}> added a note: {body}"


def already_claimed(case_id):
    return f"You are already assigned to case {case_id}"


def already_assigned(case_id, user_ids):
    verb = "is" if len(user_ids) == 1 else "are"
    return f"{people(user_ids)} {verb} already assigned to case {case_id}"


def not_assigned(case_id, user_ids):
    verb = "is" if len(user_ids) == 1 else "are"
    return f"{people(user_ids)} {verb} not assigned to case {case_id}"


def already_resolved(case_id):
    return f"Case {case_id} is already resolved"


ASSIGN_USAGE = "Usage: `!assign @user`"
UNASSIGN_USAGE = "Usage: `!unassign @user`"
NOTE_USAGE = "Usage: `!note text` or `!note @member text`"
