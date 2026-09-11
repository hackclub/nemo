import os

PREFIX = "INGEST_TOKEN_"
USER_TOKEN_PREFIX = "xoxp-"


def discover(env=None):
    env = env if env is not None else os.environ
    found = []
    for name, value in env.items():
        if not name.startswith(PREFIX):
            continue
        index = name[len(PREFIX):]
        if not index.isdigit():
            continue
        token = (value or "").strip()
        if token:
            found.append((int(index), token))
    return sorted(found, key=lambda pair: pair[0])


def names(env=None):
    return [f"{PREFIX}{index}" for index, _ in discover(env)]


def problems(env=None):
    pool = discover(env)
    seen, trouble = {}, []
    for index, token in pool:
        if not token.startswith(USER_TOKEN_PREFIX):
            trouble.append(
                f"{PREFIX}{index} is not a user token, so it cannot read a public channel "
                "it has not joined"
            )
        first = seen.setdefault(token, index)
        if first != index:
            trouble.append(f"{PREFIX}{index} repeats {PREFIX}{first}, which shares one budget")
    return trouble


def describe(env=None):
    pool = discover(env)
    if not pool:
        return f"ingest pool: no {PREFIX}n set, thread replies stay on the proxy"
    listed = ", ".join(str(index) for index, _ in pool)
    line = f"ingest pool: {len(pool)} token(s), {PREFIX}[{listed}]"
    trouble = problems(env)
    if trouble:
        line += "".join(f"\ningest pool: {note}" for note in trouble)
    return line


def report(env=None):
    print(describe(env))
    return discover(env)
