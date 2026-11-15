import datetime as dt

from lyla import writer


class Recorder:
    def __init__(self, answers=None):
        self.answers = answers or {}
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return Rows(self.answers.get(sql, []))

    def ran(self, sql):
        return [args for statement, args in self.executed if statement == sql]


class Rows:
    def __init__(self, rows):
        self.rows = rows

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


def test_snippet_flattens_lines_and_cuts_at_a_word():
    assert writer.snippet("line one\n  line two") == "line one line two"
    long = "word " * 40
    cut = writer.snippet(long)
    assert cut.endswith("...") and len(cut) <= writer.SNIPPET_LENGTH + 3
    assert writer.snippet("") is None
    assert writer.snippet(None) is None


def test_merge_into_without_target_only_marks_merged():
    lyla = Recorder()
    writer.merge_into(lyla, 5006, None)
    assert [sql for sql, _args in lyla.executed] == [writer.MERGE_STATUS]
    assert lyla.ran(writer.MERGE_STATUS) == [(None, 5006)]


def test_merge_into_moves_threads_and_assignees_then_marks_merged():
    lyla = Recorder({writer.MOVE_THREADS: [("C0FIRE", "1.1")]})
    writer.merge_into(lyla, 5006, 5001)
    assert [sql for sql, _args in lyla.executed] == [
        writer.MOVE_THREADS, writer.MOVE_ASSIGNEES, writer.DROP_ASSIGNEES, writer.MERGE_STATUS,
        writer.UCAT_PENDING]
    assert lyla.ran(writer.MERGE_STATUS) == [(5001, 5006)]


def test_merge_into_keeping_primary_promotes_the_moved_thread():
    lyla = Recorder({writer.MOVE_THREADS: [("C0FIRE", "1.1")]})
    writer.merge_into(lyla, 5014, 5011, keep_primary=True)
    assert lyla.ran(writer.PROMOTE) == [("C0FIRE", "1.1")]


def test_merge_into_keeping_primary_leaves_an_existing_primary():
    lyla = Recorder({writer.MOVE_THREADS: [("C0FIRE", "1.1")], writer.HAS_PRIMARY: [(1,)]})
    writer.merge_into(lyla, 5014, 5011, keep_primary=True)
    assert lyla.ran(writer.PROMOTE) == []


def test_apply_assignee_records_claims_as_self_and_assignments_as_manual():
    lyla = Recorder({writer.LYLA_CASE: [(5001, "open", None, None, None)]})
    sync = writer.Writer(None, lyla)
    sync.apply_assignee("insert", None, {"case_id": 5001, "user_id": "UFF1", "assigned_by": "UFF1",
                                         "assigned_at": "2026-10-22T09:00:00+00:00"})
    sync.apply_assignee("insert", None, {"case_id": 5001, "user_id": "UFF2", "assigned_by": "UFF1",
                                         "assigned_at": None})
    sync.apply_assignee("delete", {"case_id": 5001, "user_id": "UFF2"}, None)
    added = lyla.ran(writer.ADD_ASSIGNEE)
    assert [(row[0], row[1], row[3]) for row in added] == [(5001, "UFF1", "self"), (5001, "UFF2", "manual")]
    assert added[0][2] == int(dt.datetime(2026, 10, 22, 9, tzinfo=dt.UTC).timestamp() * 1000)
    assert lyla.ran(writer.DROP_ASSIGNEE) == [(5001, "UFF2")]


class NemoRows(Recorder):
    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        answer = self.answers.get(sql, [])
        return Rows(answer(args) if callable(answer) else answer)


ASSIGNED_AT = dt.datetime(2026, 11, 1, 9, 0, tzinfo=dt.UTC)


def test_unmerge_from_moves_family_threads_back_and_restores_assignees():
    conn = NemoRows({
        writer.ANCESTORS: [(5001,), (4990,)],
        writer.FAMILY_THREADS: [("C0FIRE", "1.1"), ("C0REP", "2.2")],
        writer.NEMO_ASSIGNEES: lambda args: [("UMOD", "UMOD", ASSIGNED_AT)] if args == (5006,) else [("UBOSS", "UBOSS", ASSIGNED_AT)],
    })
    lyla = NemoRows({writer.RETURN_THREAD: lambda args: [(args[1], args[2])]})

    assert writer.unmerge_from(lyla, conn, 5006, 5001) == [("C0FIRE", "1.1"), ("C0REP", "2.2")]

    assert lyla.ran(writer.RETURN_THREAD) == [(5006, "C0FIRE", "1.1", [5001, 4990]),
                                             (5006, "C0REP", "2.2", [5001, 4990])]
    assert lyla.ran(writer.PROMOTE) == [("C0FIRE", "1.1")]
    assert lyla.ran(writer.ADD_ASSIGNEE)[0][:2] == (5006, "UMOD")
    assert lyla.ran(writer.ADD_ASSIGNEE)[0][3] == "self"
    assert lyla.ran(writer.DROP_RETURNED_ASSIGNEES) == [(5001, ["UMOD"], ["UBOSS"])]


def test_unmerge_from_keeps_an_existing_primary_thread():
    conn = NemoRows({writer.ANCESTORS: [(5001,)], writer.FAMILY_THREADS: [("C0FIRE", "1.1")]})
    lyla = NemoRows({writer.RETURN_THREAD: [("C0FIRE", "1.1")], writer.HAS_PRIMARY: [(1,)]})

    writer.unmerge_from(lyla, conn, 5006, 5001)

    assert lyla.ran(writer.PROMOTE) == []
    assert lyla.ran(writer.DROP_RETURNED_ASSIGNEES) == []
