import yaml

from lib.paths import CAPABILITIES_FILE

SCOPES = ("assigned", "author", "channel")


def table():
    return yaml.safe_load(CAPABILITIES_FILE.read_text())


def capabilities(data=None):
    return (data or table())["capabilities"]


def roles(data=None):
    return (data or table())["roles"]


def flat(data=None):
    data = data or table()
    rows = []
    for key, one in capabilities(data).items():
        rows.append((
            key,
            one["label"],
            one["area"],
            one.get("record_scope"),
            bool(one.get("logged")),
            bool(one.get("every_account")),
            bool(one.get("locked")),
        ))
    return rows


def role_rows(data=None):
    data = data or table()
    return [
        (name, one["label"], bool(one.get("everything")), bool(one.get("grantable", True)))
        for name, one in roles(data).items()
    ]


def role_capability_rows(data=None):
    data = data or table()
    pairs = []
    for name, one in roles(data).items():
        for key in one.get("capabilities") or []:
            pairs.append((name, key))
    return pairs


def objections(data=None):
    data = data or table()
    known = set(capabilities(data))
    wrong = []
    for key, one in capabilities(data).items():
        scope = one.get("record_scope")
        if scope is not None and scope not in SCOPES:
            wrong.append(f"{key} declares an unknown record scope {scope!r}")
        if not one.get("area"):
            wrong.append(f"{key} declares no area")
    for name, one in roles(data).items():
        if one.get("everything") and one.get("capabilities"):
            wrong.append(f"{name} is a superadmin, it must not list capabilities")
        for key in one.get("capabilities") or []:
            if key not in known:
                wrong.append(f"{name} holds {key}, which is not a capability")
    return wrong


SYNC = """
INSERT INTO app.capability (key, label, area, record_scope, logged, every_account, locked)
VALUES (%s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (key) DO UPDATE SET
    label = EXCLUDED.label, area = EXCLUDED.area,
    record_scope = EXCLUDED.record_scope, logged = EXCLUDED.logged,
    every_account = EXCLUDED.every_account, locked = EXCLUDED.locked
"""

SYNC_ROLE = """
INSERT INTO app.role (name, label, everything, grantable)
VALUES (%s, %s, %s, %s)
ON CONFLICT (name) DO UPDATE SET
    label = EXCLUDED.label, everything = EXCLUDED.everything,
    grantable = EXCLUDED.grantable
"""

SYNC_PAIR = """
INSERT INTO app.role_capability (role, capability) VALUES (%s, %s)
ON CONFLICT DO NOTHING
"""


def sync(conn):
    data = table()
    wrong = objections(data)
    if wrong:
        raise ValueError("db/capabilities.yml is not consistent: " + "; ".join(wrong))

    rows = flat(data)
    with conn.cursor() as cur:
        cur.executemany(SYNC, rows)
        cur.executemany(SYNC_ROLE, role_rows(data))
        cur.execute("DELETE FROM app.capability WHERE key <> ALL(%s)", ([r[0] for r in rows],))
        cur.execute("DELETE FROM app.role WHERE name <> ALL(%s)",
                    ([r[0] for r in role_rows(data)],))
        pairs = role_capability_rows(data)
        cur.executemany(SYNC_PAIR, pairs)
        cur.execute(
            "DELETE FROM app.role_capability WHERE (role, capability) NOT IN ("
            "SELECT r, c FROM unnest(%s::text[], %s::text[]) AS kept(r, c))",
            ([one[0] for one in pairs], [one[1] for one in pairs]),
        )
    return len(rows), len(pairs)
