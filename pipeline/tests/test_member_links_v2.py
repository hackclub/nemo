import contextlib
import pathlib

from ingest import member_links as links
from ingest import member_links_v2 as v2


def test_every_signal_belongs_to_a_family_with_a_cap():
    caps = v2.families()
    for name, one in links.signals().items():
        assert one["family"] in caps, name
    for family, one in caps.items():
        assert one["cap"] > 0, family


def test_no_family_alone_reaches_certain():
    certain = links.scoring()["certain"]
    for family, one in v2.families().items():
        assert one["cap"] < certain, family


def test_the_family_table_lines_up_signal_by_signal():
    table = v2.family_table(links.catalogue())

    assert len({len(column) for column in table.values()}) == 1
    at = table["signals"].index("session_agent")
    assert table["families"][at] == "device"
    assert table["corroborating"][at] is True


def test_each_family_is_capped_before_the_families_are_added():
    assert "least(sum(b.score), f.cap)" in v2.PASS
    assert "bool_or(NOT corroborating)" in v2.PASS


def test_an_unchanged_link_is_not_written_again():
    assert "IS DISTINCT FROM" in v2.LAND
    assert "NOT EXISTS (SELECT 1 FROM link_pass" in v2.SWEEP
    assert "computed_at" not in v2.SWEEP


def test_links_v2_are_held_one_way_round():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
           / "0184_member_link_v2.sql").read_text()
    assert "CHECK (a_user_id < b_user_id)" in sql
    assert "PRIMARY KEY (a_user_id, b_user_id)" in sql


def test_a_pass_gathers_once_then_lands_sweeps_and_counts(monkeypatch, capsys):
    ran = []

    class Counts:
        rows_in = 0
        rows_rejected = 0

    class Cursor:
        rowcount = 0

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def execute(self, sql, _params=None):
            ran.append(sql)
            self.rowcount = {v2.LAND: 4, v2.SWEEP: 1}.get(sql, 0)

        def fetchone(self):
            return (9,)

    class Conn:
        def cursor(self):
            return Cursor()

        def commit(self):
            ran.append("commit")

    @contextlib.contextmanager
    def bookkeeping(*_args, **_kwargs):
        yield Counts()

    monkeypatch.setattr(v2, "ingest_run", bookkeeping)
    monkeypatch.setattr(links, "mark_shared", lambda _conn, _held: 2)
    monkeypatch.setattr(links, "gather", lambda _conn, _held: {"ip_exact": 3})

    assert v2.run(Conn()) == 4
    assert ran[:4] == [v2.PASS, v2.PASS_INDEX, v2.LAND, v2.SWEEP]
    assert ran[-1] == "commit"
    assert "9 link(s) kept, 4 written, 1 dropped, 2 address(es)" in capsys.readouterr().out
