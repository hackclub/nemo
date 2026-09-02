import yaml

from lib.paths import CAPABILITIES_FILE

SCOPES = ("assigned", "author", "channel")


def table():
    return yaml.safe_load(CAPABILITIES_FILE.read_text())


def capabilities(said=None):
    return (said or table())["capabilities"]


def roles(said=None):
    return (said or table())["roles"]


def flat(said=None):
    said = said or table()
    rows = []
    for key, one in capabilities(said).items():
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


def role_rows(said=None):
    said = said or table()
    return [
        (name, one["label"], bool(one.get("everything")), bool(one.get("grantable", True)))
        for name, one in roles(said).items()
    ]


def role_capability_rows(said=None):
    said = said or table()
    pairs = []
    for name, one in roles(said).items():
        for key in one.get("capabilities") or []:
            pairs.append((name, key))
    return pairs


def objections(said=None):
    said = said or table()
    known = set(capabilities(said))
    wrong = []
    for key, one in capabilities(said).items():
        scope = one.get("record_scope")
        if scope is not None and scope not in SCOPES:
            wrong.append(f"{key} declares an unknown record scope {scope!r}")
        if not one.get("area"):
            wrong.append(f"{key} declares no area")
    for name, one in roles(said).items():
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
    said = table()
    wrong = objections(said)
    if wrong:
        raise ValueError("db/capabilities.yml is not consistent: " + "; ".join(wrong))

    rows = flat(said)
    with conn.cursor() as cur:
        cur.executemany(SYNC, rows)
        cur.executemany(SYNC_ROLE, role_rows(said))
        cur.execute("DELETE FROM app.capability WHERE key <> ALL(%s)", ([r[0] for r in rows],))
        cur.execute("DELETE FROM app.role WHERE name <> ALL(%s)",
                    ([r[0] for r in role_rows(said)],))
        pairs = role_capability_rows(said)
        cur.executemany(SYNC_PAIR, pairs)
        cur.execute(
            "DELETE FROM app.role_capability WHERE (role, capability) NOT IN ("
            "SELECT r, c FROM unnest(%s::text[], %s::text[]) AS kept(r, c))",
            ([one[0] for one in pairs], [one[1] for one in pairs]),
        )
    return len(rows), len(pairs)
