import datetime as dt

from bot.core import case as core_case
from bot.nemo import case_actions

CASE_ID = 41
REPORT_ID = 31
MODERATOR_ID = "UMODERATOR"
CLOSED_AT = dt.datetime(2026, 10, 1, 12, 0, tzinfo=dt.UTC)

RECORD_REPORTER_REPLY = "SET reporter_replied_at = now()"
SLACK_REOPEN = "RETURNING resolution"
REOPEN_REPORTS = "UPDATE fd.case_reports r"
AUDIT_INSERT = "INSERT INTO fd.audit"


class Conn:
    def __init__(self, fetchone_rows=None, fetchall_rows=None):
        self.fetchone_rows = fetchone_rows or {}
        self.fetchall_rows = fetchall_rows or {}
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        return self.match(self.fetchone_rows)

    def fetchall(self):
        return self.match(self.fetchall_rows) or []

    def match(self, rows):
        sql = self.executed[-1][0]
        for marker, row in rows.items():
            if marker in sql:
                return row
        return None

    def args_for(self, marker):
        return [args for sql, args in self.executed if marker in sql]

    def report_audits(self):
        return [args for args in self.args_for(AUDIT_INSERT) if args[2] == "report"]


def closed_report_rows():
    return {REOPEN_REPORTS: [(REPORT_ID, CLOSED_AT, MODERATOR_ID)]}


def test_record_reporter_reply_resolved_case_sets_flag_without_reopening():
    conn = Conn({RECORD_REPORTER_REPLY: (CASE_ID,)}, closed_report_rows())

    assert core_case.record_reporter_reply(conn, CASE_ID) is True
    assert conn.args_for(RECORD_REPORTER_REPLY) == [(CASE_ID,)]
    assert conn.args_for(REOPEN_REPORTS) == []
    assert conn.args_for(AUDIT_INSERT) == []


def test_record_reporter_reply_open_or_flagged_case_returns_false():
    conn = Conn({RECORD_REPORTER_REPLY: None})

    assert core_case.record_reporter_reply(conn, CASE_ID) is False


def test_record_reporter_reply_sql_is_one_time_per_resolved_case():
    sql = core_case.RECORD_REPORTER_REPLY

    assert "resolved_at IS NOT NULL" in sql
    assert "reporter_replied_at IS NULL" in sql
    assert "resolved_at = NULL" not in sql


def test_case_actions_reopen_closed_case_reopens_closed_reports():
    conn = Conn({SLACK_REOPEN: ("action_taken",)}, closed_report_rows())

    assert case_actions.reopen(conn, CASE_ID, MODERATOR_ID) is True
    assert conn.args_for(REOPEN_REPORTS) == [(CASE_ID,)]
    assert [(args[3], args[4]) for args in conn.report_audits()] == [(REPORT_ID, "reopened")]


def test_reopen_reports_writes_audit_with_previous_closure():
    conn = Conn(fetchall_rows=closed_report_rows())

    assert core_case.reopen_reports(conn, CASE_ID, MODERATOR_ID) == [REPORT_ID]

    audit_args = conn.report_audits()[0]
    assert audit_args[0] == MODERATOR_ID
    assert audit_args[5].obj == {"closed_at": str(CLOSED_AT), "closed_by": MODERATOR_ID}
    assert audit_args[6].obj == {"closed_at": None, "closed_by": None, "case_id": CASE_ID}


def test_case_actions_reopen_without_closed_reports_writes_no_report_audit():
    conn = Conn({SLACK_REOPEN: ("no_action",)}, {REOPEN_REPORTS: []})

    assert case_actions.reopen(conn, CASE_ID, MODERATOR_ID) is True
    assert conn.report_audits() == []


def test_case_actions_reopen_does_not_touch_assignees():
    conn = Conn({SLACK_REOPEN: ("action_taken",)}, closed_report_rows())

    case_actions.reopen(conn, CASE_ID, MODERATOR_ID)

    assert not [sql for sql, _args in conn.executed if "case_assignees" in sql]


MERGE = "SET resolved_at = now(), resolution = 'duplicate'"


def test_merge_with_closed_duplicates_copies_assignees_to_target():
    conn = Conn({MERGE: (CLOSED_AT,)}, {"INSERT INTO fd.case_assignees": [("UHELPER",)]})

    assert case_actions.merge(conn, CASE_ID, [42, 43], MODERATOR_ID) == [42, 43]
    assert conn.args_for("INSERT INTO fd.case_assignees") == [(CASE_ID, MODERATOR_ID, [42, 43])]
    assignee_audits = [args for args in conn.args_for(AUDIT_INSERT) if args[2] == "assignee"]
    assert [(args[3], args[4], args[6].obj) for args in assignee_audits] == \
        [(CASE_ID, "attached", {"user_id": "UHELPER", "source_case_ids": [42, 43]})]


def test_merge_without_closed_duplicates_copies_no_assignees():
    conn = Conn({MERGE: None})

    assert case_actions.merge(conn, CASE_ID, [42], MODERATOR_ID) == []
    assert conn.args_for("INSERT INTO fd.case_assignees") == []
