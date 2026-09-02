import yaml

from bot.engine import access
from lib.paths import DB_DIR

CHECKS = yaml.safe_load((DB_DIR / "permission_checks.yml").read_text())["checks"]

ME = "UME"
THEM = "UTHEM"
CASE_ID = 4242


class Answer:
    def __init__(self, rows):
        self.rows = rows

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


class Conn:
    def __init__(self, role=None, moved=None, holders=(), manager=False):
        self.role = role
        self.moved = moved or {}
        self.holders = holders
        self.manager = manager

    def execute(self, sql, params):
        if sql is access.ROLE:
            return Answer([(self.role,)] if self.role else [])
        if sql is access.MANAGER:
            return Answer([(1,)] if self.manager else [])
        if sql is access.MOVED:
            return Answer(list(self.moved.items()))
        if sql is access.HOLDERS:
            assert params == (CASE_ID,)
            return Answer([(one,) for one in self.holders])
        raise AssertionError(f"the gate ran a query the test does not know: {sql}")


def conn_for(check):
    holders = {"free": (), "mine": (ME,), "theirs": (THEM,)}[check.get("case", "free")]
    return Conn(role=check.get("role"), moved=check.get("moved"), holders=holders,
                manager=check.get("manager", False))


def test_every_check_in_the_shared_file_agrees():
    wrong = []
    for check in CHECKS:
        case_id = CASE_ID if check.get("case") else None
        allowed, refusal = access.may(conn_for(check), ME, check["key"], case_id)

        if allowed != check["allowed"]:
            wrong.append(f"{check['name']}: got {allowed}, wanted {check['allowed']}")
        if not allowed and not refusal:
            wrong.append(f"{check['name']}: refused without saying why")

    assert not wrong, "\n".join(wrong)


def test_a_grant_alone_is_no_longer_enough():
    conn = Conn(role="firefighter", holders=(THEM,))

    allowed, refusal = access.may(conn, ME, "case.act", CASE_ID)

    assert allowed is False
    assert "not with you" in refusal


def test_the_refusal_names_the_role_that_holds_it():
    conn = Conn(role="lead")

    allowed, refusal = access.may(conn, ME, "access.grant")

    assert allowed is False
    assert refusal == "give or take back access is community manager only"


def test_an_unknown_permission_is_a_mistake_not_a_refusal():
    try:
        access.may(Conn(role="lead"), ME, "case.explode")
    except KeyError as gone:
        assert "case.explode" in str(gone)
    else:
        raise AssertionError("an unknown key should raise, not quietly refuse")


def test_the_table_matches_the_one_rails_reads():
    keys = set(access.table()["permissions"])

    assert "case.act" in keys
    assert access.entry("case.act")["scope"] == "assigned"
    assert access.default_roles("access.grant") == ["community_manager"]
    assert access.rank()[0] == "firefighter"
