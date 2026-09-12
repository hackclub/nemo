from datetime import date

from jobs import invariants


class OneRow:
    def __init__(self, row):
        self.row = row

    def execute(self, sql, params=None):
        return self

    def fetchone(self):
        return self.row

    def fetchall(self):
        return [self.row] if self.row else []


def test_the_status_vocabulary_is_read_out_of_the_constraint():
    conn = OneRow(("CHECK ((status = ANY (ARRAY['running'::text, 'ok'::text, 'failed'::text, "
                   "'skipped'::text, 'partial'::text, 'cancelled'::text, 'abandoned'::text])))",))
    assertion, status, observed, expected = invariants.i10_status_vocabulary_matches_the_check(conn)
    assert (assertion, status) == ("I10", "pass")
    assert observed == expected


def test_a_missing_status_value_fails_i10():
    conn = OneRow(("CHECK ((status = ANY (ARRAY['running'::text, 'ok'::text, 'failed'::text])))",))
    assert invariants.i10_status_vocabulary_matches_the_check(conn)[1] == "fail"


def test_a_missing_constraint_fails_i10():
    assert invariants.i10_status_vocabulary_matches_the_check(OneRow(None))[1] == "fail"


def test_i1_passes_when_every_planned_stage_wrote_a_row():
    assert invariants.i1_every_planned_stage_has_a_row(OneRow(("2026-09-05", 20, 20)))[1] == "pass"
    assert invariants.i1_every_planned_stage_has_a_row(OneRow(("2026-09-05", 18, 20)))[1] == "fail"
    assert invariants.i1_every_planned_stage_has_a_row(OneRow(None))[1] == "pass"


def test_i4_flags_a_count_column_defaulted_to_zero():
    class Rows(OneRow):
        def fetchall(self):
            return [("ingest.work_item.fetched", "NO", "0"), ("raw.ingest_run.rows_in", "YES", None)]
    assertion, status, observed, _ = invariants.i4_counts_are_nullable(Rows(None))
    assert (assertion, status) == ("I4", "fail")
    assert observed == "ingest.work_item.fetched"


def test_severity_is_info_on_pass_and_error_on_fail_except_i4():
    assert invariants.severity_of("I1", "pass") == "info"
    assert invariants.severity_of("I1", "fail") == "error"
    assert invariants.severity_of("I4", "fail") == "warn"


def test_every_check_is_registered_once():
    names = [check.__name__ for check in invariants.CHECKS]
    assert len(names) == len(set(names)) == 7


class DaySource:
    def __init__(self, rows):
        self.rows = rows

    def execute(self, sql, params=None):
        return self

    def fetchall(self):
        return self.rows


def test_a_fresh_day_source_passes():
    conn = DaySource([("member_day", "2026-09-09", 2), ("channel_day", "2026-09-09", 2)])
    assertion, status, observed, _ = invariants.i11_every_day_source_is_recent(conn)
    assert (assertion, status) == ("I11", "pass")
    assert "worst 2d" in observed


def test_a_frozen_day_source_fails_and_names_itself():
    conn = DaySource([("member_day", "2026-09-09", 2), ("channel_day", "2026-07-01", 72)])
    assertion, status, observed, _ = invariants.i11_every_day_source_is_recent(conn)
    assert (assertion, status) == ("I11", "fail")
    assert "channel_day stopped at 2026-07-01 (72d)" in observed
    assert "member_day" not in observed


def test_the_lag_bar_sits_above_slacks_normal_two_day_lag():
    assert invariants.DAY_LAG_LIMIT > 2
    conn = DaySource([("member_day", "2026-09-08", invariants.DAY_LAG_LIMIT)])
    assert invariants.i11_every_day_source_is_recent(conn)[1] == "pass"
    conn = DaySource([("member_day", "2026-09-08", invariants.DAY_LAG_LIMIT + 1)])
    assert invariants.i11_every_day_source_is_recent(conn)[1] == "fail"


def test_a_frozen_source_is_an_error_not_a_warning():
    assert invariants.severity_of("I11", "fail") == "error"


class Ledgers:
    def __init__(self, answers):
        self.answers = list(answers)
        self.last = None

    def execute(self, sql, params=None):
        self.last = self.answers.pop(0)
        return self

    def fetchone(self):
        return self.last


ERA = (date(2026, 7, 15), date(2026, 9, 11))


def test_ledgers_with_no_slices_yet_pass():
    conn = Ledgers([(None, None), (None, None)])
    assertion, status, observed, _ = invariants.i12_the_day_ledgers_agree(conn)
    assert (assertion, status) == ("I12", "pass")
    assert "no day source has claimed a slice" in observed


def test_agreeing_ledgers_pass():
    conn = Ledgers([ERA, (0, 0), ERA, (0, 0)])
    _, status, observed, _ = invariants.i12_the_day_ledgers_agree(conn)
    assert status == "pass"
    assert "2 day source(s) agree" in observed


def test_a_complete_slice_with_no_loaded_day_fails():
    conn = Ledgers([ERA, (0, 3), ERA, (0, 0)])
    _, status, observed, _ = invariants.i12_the_day_ledgers_agree(conn)
    assert status == "fail"
    assert "3 complete slice(s) with no loaded day" in observed


def test_a_loaded_day_inside_the_era_with_no_slice_fails():
    conn = Ledgers([ERA, (0, 0), ERA, (4, 0)])
    _, status, observed, _ = invariants.i12_the_day_ledgers_agree(conn)
    assert status == "fail"
    assert "4 loaded day(s) with no slice" in observed
