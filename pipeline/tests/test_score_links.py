import pytest
from psycopg import errors

from jobs import score_links as links
from lib.graph import components

MARKS = {"floor": 3.0, "strong": 5.0, "certain": 8.0}


class Result:
    def __init__(self, rows):
        self.rows = rows

    def fetchall(self):
        return self.rows


class Conn:
    def __init__(self, answers):
        self.answers = answers

    def execute(self, query, params=None):
        text = query if isinstance(query, str) else query.as_string(None)
        for marker, rows in self.answers.items():
            if marker in text:
                return Result(rows(params) if callable(rows) else rows)
        raise AssertionError(f"unexpected query: {text}")


def test_gmail_dots_and_plus_tags_fold_into_one_mailbox():
    assert links.mailbox("A.B+x@GoogleMail.com") == "ab@gmail.com"
    assert links.mailbox("ab@gmail.com") == "ab@gmail.com"


def test_dots_only_fold_on_gmail():
    assert links.mailbox("a.b+x@school.edu") == "a.b@school.edu"


def test_an_address_without_a_mailbox_is_skipped():
    assert links.mailbox("nope") is None
    assert links.mailbox("+x@gmail.com") is None
    assert links.mailbox(None) is None


def test_staff_domains_match_their_subdomains_only():
    assert links.staff_domain("hackclub.com", ["hackclub.com"])
    assert links.staff_domain("mail.hackclub.com", ["hackclub.com"])
    assert not links.staff_domain("nothackclub.com", ["hackclub.com"])


def test_alias_pairs_leave_out_staff_domains():
    rows = [("U3", "a.b@gmail.com"), ("U1", "ab+z@gmail.com"), ("U2", "x@hackclub.com"),
            ("U4", "x+1@hackclub.com"), ("U5", "solo@x.org")]

    assert links.alias_pairs(rows, ["hackclub.com"]) == {("U1", "U3")}


def test_people_join_chains_of_pairs():
    assert components([("U1", "U2"), ("U3", "U2"), ("U7", "U8")]) == [
        {"U1", "U2", "U3"}, {"U7", "U8"}]


def test_together_counts_the_largest_group_linked_among_the_accounts():
    person = {"U1", "U2", "U3", "U4"}

    assert links.together(person, [("U1", "U2"), ("U2", "U3"), ("U4", "U9")]) == 3
    assert links.together(person, []) == 0


def test_the_hub_is_the_account_in_most_pairs():
    assert links.hub({"U1", "U2", "U3", "U5"}, {("U1", "U5"), ("U2", "U5"), ("U3", "U5")}) == "U5"


def test_bands_follow_the_scoring_marks():
    assert links.band_of(9, MARKS) == "certain"
    assert links.band_of(5, MARKS) == "strong"
    assert links.band_of(3, MARKS) == "worth a look"


def test_only_schema_qualified_lowercase_tables_are_scored():
    assert links.links_table("fd.member_link").as_string(None) == '"fd"."member_link"'
    for name in ("member_link", "fd.member_link;drop", "FD.member_link", ""):
        with pytest.raises(ValueError):
            links.links_table(name)


def test_measure_scores_verdicts_people_and_aliases(monkeypatch):
    monkeypatch.setattr(links, "scoring", lambda: MARKS)
    monkeypatch.setattr(links, "catalogue", lambda: {"staff_domains": ["hackclub.com"]})
    among = [("U1", "U2", 9.0), ("U2", "U3", 4.0), ("U6", "U7", 5.5)]
    conn = Conn({
        "count(*) FILTER": [(1, 2, 3)],
        "FROM fd.member_link_verdict": [
            ("U1", "U2", "same_person", 9.0), ("U2", "U3", "same_person", 4.0),
            ("U3", "U4", "same_person", None), ("U5", "U8", "different_people", None)],
        "ANY(%(ids)s)": lambda params: [row for row in among
                                        if row[0] in params["ids"] and row[1] in params["ids"]],
        "FROM fd.member_identity": [("U6", "a.b@gmail.com"), ("U7", "ab@gmail.com"),
                                    ("U8", "x@hackclub.com"), ("U9", "x+1@hackclub.com")],
    })

    result = links.measure(conn)

    assert result["bands"] == {"certain": 1, "strong": 2, "worth a look": 3}
    same = result["verdicts"]["same_person"]
    assert (same["pairs"], same["linked"]) == (3, 2)
    assert same["bands"] == {"certain": 1, "worth a look": 1}
    assert result["verdicts"]["household"]["pairs"] == 0
    assert result["people"] == [
        {"hub": "U2", "accounts": 4, "together": 3, "strong_together": 2}]
    assert (result["aliases"]["pairs"], result["aliases"]["linked"]) == (1, 1)
    assert result["aliases"]["bands"] == {"strong": 1}


def test_render_reports_shares_of_each_count():
    result = {
        "links": "fd.member_link",
        "bands": {"certain": 1, "strong": 2, "worth a look": 3},
        "verdicts": {"same_person": {"pairs": 4, "linked": 2, "bands": {"certain": 2}}},
        "people": [{"hub": "U2", "accounts": 4, "together": 3, "strong_together": 2}],
        "aliases": {"pairs": 0, "linked": 0, "bands": {}},
    }

    text = "\n".join(links.render(result))

    assert "links in fd.member_link: 6 (certain 1, strong 2, worth a look 3)" in text
    assert "same_person" in text and "2 of 4" in text and "50%" in text
    assert "3 linked together (75%)" in text
    assert "email aliases outside staff domains: 0 of 0 linked (n/a)" in text


def test_a_bad_links_table_exits_2_without_connecting(monkeypatch, capsys):
    monkeypatch.setattr(links, "load_dotenv", lambda *_args: None)
    monkeypatch.setattr(links, "connect", lambda *_args: pytest.fail("connected"))

    assert links.main(["--links", "fd.member_link;drop"]) == 2
    assert "not a schema.table name" in capsys.readouterr().err


def test_a_missing_links_table_exits_2_with_the_database_message(monkeypatch, capsys):
    class Missing:
        read_only = False

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def execute(self, *_args):
            raise errors.UndefinedTable('relation "fd.nope" does not exist\nLINE 4: FROM "fd"."nope"')

    monkeypatch.setattr(links, "load_dotenv", lambda *_args: None)
    monkeypatch.setattr(links, "scoring", lambda: MARKS)
    monkeypatch.setattr(links, "catalogue", lambda: {})
    monkeypatch.setattr(links, "connect", lambda *_args: Missing())

    assert links.main(["--links", "fd.nope"]) == 2
    assert capsys.readouterr().err == 'check-links: relation "fd.nope" does not exist\n'
