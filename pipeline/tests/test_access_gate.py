import os

import pytest
import yaml
from dotenv import load_dotenv

from bot.engine import access
from lib.paths import DB_DIR

load_dotenv(DB_DIR.parent / "deploy" / ".env")
os.environ["POSTGRES_DB"] = os.environ.get("POSTGRES_TEST_DB", "mnemosyne_test")

from lib.db import connect_admin  # noqa: E402

CHECKS = yaml.safe_load((DB_DIR / "permission_checks.yml").read_text())["checks"]

ME = "UME"
THEM = "UTHEM"
BY = "gatetest"


@pytest.fixture
def conn():
    with connect_admin() as open_conn:
        yield open_conn
        open_conn.rollback()


def clear(conn):
    conn.execute("DELETE FROM app.grant WHERE granted_by = %s", (BY,))
    conn.execute("DELETE FROM app.role_override")
    conn.execute("DELETE FROM app.staff WHERE user_id = %s", (ME,))
    conn.execute("DELETE FROM fd.access_grants WHERE granted_by = %s", (BY,))


def hold(conn, check):
    if check.get("manager"):
        conn.execute(
            "INSERT INTO app.staff (user_id, community_manager, created_at, updated_at) "
            "VALUES (%s, true, now(), now())", (ME,)
        )
    elif check.get("role"):
        conn.execute(
            "INSERT INTO app.grant (user_id, kind, name, granted_by) VALUES (%s,'role',%s,%s)",
            (ME, "firefighter" if check["role"] == "lead" else check["role"], BY),
        )
    for role, allowed in (check.get("moved") or {}).items():
        want = "firefighter" if role == "lead" else role
        conn.execute(
            "INSERT INTO app.role_override (role, capability, allowed, changed_by) "
            "VALUES (%s,%s,%s,%s) ON CONFLICT (role, capability) DO UPDATE SET allowed = EXCLUDED.allowed",
            (want, check["key"], allowed, BY),
        )


def a_case(conn, kind):
    if not kind:
        return None
    conn.execute("INSERT INTO fd.cases (opened_by, source_app) VALUES (%s,'fire_engine')", (ME,))
    case_id = conn.execute("SELECT max(id) FROM fd.cases").fetchone()[0]
    who = {"mine": ME, "theirs": THEM}.get(kind)
    if who:
        conn.execute(
            "INSERT INTO fd.case_assignees (case_id, user_id, assigned_by) VALUES (%s,%s,%s)",
            (case_id, who, ME),
        )
    return case_id


def test_every_check_in_the_shared_file_agrees(conn):
    wrong = []
    for check in CHECKS:
        clear(conn)
        hold(conn, check)
        case_id = a_case(conn, check.get("case"))

        allowed, refusal = access.may(conn, ME, check["key"], case_id)
        if allowed != check["allowed"]:
            wrong.append(f"{check['name']}: got {allowed}, wanted {check['allowed']}")
        if not allowed and not refusal:
            wrong.append(f"{check['name']}: refused without saying why")

    clear(conn)
    assert not wrong, "\n".join(wrong)


def test_an_unknown_capability_is_refused_rather_than_silently_false(conn):
    with pytest.raises(access.Unknown):
        access.may(conn, ME, "case.explode")


def test_nobody_without_a_grant_holds_a_conduct_capability(conn):
    clear(conn)
    allowed, refusal = access.may(conn, "UNOBODY", "case.act")
    assert not allowed
    assert "grant" in refusal


def test_every_account_capabilities_need_no_grant(conn):
    clear(conn)
    allowed, _ = access.may(conn, "UNOBODY", "slack.link")
    assert allowed
