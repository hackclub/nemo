import pathlib

import pytest

from jobs import link_verdicts as verdicts
from jobs.link_verdicts import VerdictError


class Result:
    def __init__(self, rows):
        self.rows = rows

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


class Conn:
    def __init__(self, held=None, members=()):
        self.held = dict(held or {})
        self.members = set(members)
        self.calls = []
        self.committed = False

    def execute(self, sql, params=None):
        self.calls.append((sql.strip(), params))
        if sql == verdicts.KNOWN_SQL:
            return Result([(one,) for one in params[0] if one in self.members])
        if sql == verdicts.HELD_SQL:
            held = self.held.get(tuple(params))
            return Result([held] if held else [])
        if sql == verdicts.INSERT_SQL:
            return Result([(41,)])
        return Result([])

    def commit(self):
        self.committed = True

    def did(self, prefix):
        return [params for sql, params in self.calls if sql.startswith(prefix)]


def test_a_pair_is_stored_lowest_id_first():
    assert verdicts.ordered("U02", "U01") == ("U01", "U02")
    assert verdicts.ordered("U01", "U02") == ("U01", "U02")


def test_one_person_verdicts_are_linked_and_the_rest_unlinked():
    assert verdicts.verb_for("same_person") == "linked"
    assert verdicts.verb_for("staff_test") == "linked"
    assert verdicts.verb_for("different_people") == "unlinked"
    assert verdicts.verb_for("household") == "unlinked"


def test_the_verdicts_match_the_table_check():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
           / "0181_member_link_verdicts.sql").read_text()
    for verdict in verdicts.VERDICTS:
        assert f"'{verdict}'" in sql


def test_ids_split_on_commas_and_spaces():
    picks = verdicts.planned("U09", "U01", {"same_person": ["U02,U03", " U04 "], "household": ["U05"]})

    assert picks == {"U02": "same_person", "U03": "same_person", "U04": "same_person",
                     "U05": "household"}


def test_an_account_under_two_verdicts_is_refused():
    with pytest.raises(VerdictError, match="U02 is listed under both"):
        verdicts.planned("U09", "U01", {"same_person": ["U02"], "household": ["U02"]})


def test_the_main_account_cannot_be_paired_with_itself():
    with pytest.raises(VerdictError, match="main account"):
        verdicts.planned("U09", "U01", {"same_person": ["U01"]})


def test_malformed_ids_are_refused():
    with pytest.raises(VerdictError, match="nobody, x1"):
        verdicts.planned("nobody", "U01", {"same_person": ["x1", "U02"]})


def test_nothing_listed_is_refused():
    with pytest.raises(VerdictError, match="--same-person"):
        verdicts.planned("U09", "U01", {})


def test_a_new_pair_is_inserted_and_audited_against_the_listed_account():
    conn = Conn()

    assert verdicts.record(conn, "U09", "U05", "U02", "same_person") == "recorded"

    assert conn.did("INSERT INTO fd.member_link_verdict") == [("U02", "U05", "same_person", "U09", None)]
    [row] = conn.did("INSERT INTO fd.audit")
    assert row[0] == "U09"
    assert row[2:5] == ("member_link_verdict", 41, "linked")
    assert row[5] is None
    assert row[6].obj["verdict"] == "same_person"
    assert row[8] == "U02"


def test_the_same_verdict_again_writes_nothing():
    conn = Conn(held={("U02", "U05"): (7, "same_person", "U08", None)})

    assert verdicts.record(conn, "U09", "U05", "U02", "same_person") == "unchanged"

    assert conn.did("UPDATE") == []
    assert conn.did("INSERT") == []


def test_a_changed_verdict_keeps_the_note_and_audits_the_old_verdict():
    conn = Conn(held={("U02", "U05"): (7, "same_person", "U08", "shared a laptop")})

    assert verdicts.record(conn, "U09", "U05", "U02", "household") == "changed"

    assert conn.did("UPDATE fd.member_link_verdict") == [("household", "U09", "shared a laptop", 7)]
    [row] = conn.did("INSERT INTO fd.audit")
    assert row[4] == "unlinked"
    assert row[5].obj == {"verdict": "same_person", "decided_by": "U08", "note": "shared a laptop"}
    assert row[6].obj["verdict"] == "household"


def test_unknown_accounts_stop_the_run_before_anything_is_written():
    conn = Conn(members={"U09", "U05"})

    with pytest.raises(VerdictError, match="not in fd.member: U02"):
        verdicts.run(conn, "U09", "U05", {"U02": "same_person"})

    assert conn.did("INSERT") == []
    assert not conn.committed


def test_a_run_commits_after_every_pair():
    conn = Conn(members={"U09", "U05", "U02", "U03"})

    tally = verdicts.run(conn, "U09", "U05", {"U02": "same_person", "U03": "staff_test"})

    assert tally == {"recorded": 2}
    assert conn.committed


def test_a_refusal_exits_2_without_connecting(monkeypatch, capsys):
    monkeypatch.setattr(verdicts, "load_dotenv", lambda *_args: None)
    monkeypatch.setattr(verdicts, "connect", lambda *_args: pytest.fail("connected"))

    assert verdicts.main(["--by", "U09", "--main", "U01", "--same-person", "U01"]) == 2
    assert "main account" in capsys.readouterr().err
