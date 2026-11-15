import datetime as dt

from bot.nemo import card_facts

AT = dt.datetime(2026, 11, 15, 12, 0, tzinfo=dt.UTC)


class Conn:
    def __init__(self, facts):
        self.facts = facts
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        return self.facts

    def fetchall(self):
        return []


def fe(case_id):
    return f"https://fe/cases/{case_id}"


def slack(conn, case_id):
    return f"https://slack/{case_id}"


def test_enrich_links_main_case_in_fire_engine_and_slack():
    case = card_facts.enrich(None, Conn((5633, AT, "UMOD")), {"case_id": 5615}, fe, slack)

    assert case["duplicate_url"] == "https://fe/cases/5633"
    assert case["duplicate_thread_url"] == "https://slack/5633"


def test_enrich_reads_main_case_thread_on_the_same_connection():
    conn = Conn((5633, AT, "UMOD"))
    seen = []

    card_facts.enrich(None, conn, {"case_id": 5615}, fe, lambda used, case_id: seen.append((used, case_id)))

    assert seen == [(conn, 5633)]


def test_enrich_skips_thread_for_a_case_not_merged():
    case = card_facts.enrich(None, Conn((None, AT, None)), {"case_id": 5615}, fe, slack)

    assert "duplicate_thread_url" not in case and "duplicate_url" not in case
