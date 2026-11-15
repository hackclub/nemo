import datetime as dt

from bot.nemo import record

AT = dt.datetime(2026, 10, 17, 12, 0, tzinfo=dt.UTC)


class Conn:
    def __init__(self, counts=(0, 0, 0, 0, 0), in_force=None, actions=(), notes=()):
        self.counts = counts
        self.in_force = in_force
        self.actions = list(actions)
        self.notes = list(notes)
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        sql = self.executed[-1][0]
        if "AS case_count" in sql:
            return self.counts
        return self.in_force if "fd.member_guards" in sql else None

    def fetchall(self):
        sql = self.executed[-1][0]
        return self.actions if "FROM fd.actions" in sql else self.notes


def test_read_maps_counts_actions_and_notes():
    conn = Conn(
        counts=(9, 1, 3, 1, 2),
        actions=[("shush", 44, "UMOD", AT, None, "spam", None, None, None, {"channel_id": "C1"})],
        notes=[("UMOD", "bad", AT)],
    )

    result = record.read(conn, "UM")

    assert result["counts"] == {"case_count": 9, "open_case_count": 1, "action_count": 3,
                                "reversed_action_count": 1, "note_count": 2}
    assert result["actions"][0]["channel_id"] == "C1" and result["actions"][0]["reason"] == "spam"
    assert result["notes"] == [{"author": "UMOD", "body": "bad", "created_at": AT}]
    assert result["in_force"] is None


def test_read_applies_limits_to_actions_and_notes():
    conn = Conn()

    record.read(conn, "UM")

    limits = [args["limit"] for sql, args in conn.executed if "LIMIT %(limit)s" in sql]
    assert limits == [record.ACTIONS_LIMIT, record.NOTES_LIMIT]


def test_read_maps_in_force_guard():
    conn = Conn(in_force=("shush", AT, None, 44, "held", "nemo"))

    assert record.read(conn, "UM")["in_force"]["case_id"] == 44


def test_actions_sql_includes_reversed_actions_newest_first():
    assert "reversed_at IS NULL" not in record.RECENT_ACTIONS
    assert "ORDER BY performed_at DESC" in record.RECENT_ACTIONS


def test_notes_sql_skips_deleted_notes():
    assert "deleted_at IS NULL" in record.RECENT_NOTES


def test_build_view_without_record_says_nothing_active_and_no_record():
    view = record.build_view(Conn(), "UM")

    assert view["blocks"][0]["text"]["text"] == "*<@UM>*  Nothing active"
    assert view["blocks"][1]["elements"][0]["text"] == "No record"


def test_build_view_summarises_guard_counts_and_entries():
    conn = Conn(
        counts=(9, 1, 3, 1, 1),
        in_force=("shush", AT, None, 44, "held", "nemo"),
        actions=[("shush", 44, "UMOD", AT, AT, "spam", None, None, None, {})],
        notes=[("UMOD", "bad", AT)],
    )

    view = record.build_view(conn, "UM", can_note=True)
    text = str(view["blocks"])

    assert "case 44" in view["blocks"][0]["text"]["text"].lower()
    assert view["blocks"][1]["elements"][0]["text"] == "9 cases, 1 open, 3 actions, 1 reversed, 1 note"
    assert "*Shush*" in text and "bad" in text and "member_add_note" in text


def test_build_view_links_each_action_case_to_its_slack_thread(monkeypatch):
    monkeypatch.setattr(record.channel, "thread_url", lambda conn, case_id: f"https://slack/{case_id}")
    conn = Conn(counts=(1, 0, 1, 0, 0), actions=[("shush", 44, "UMOD", AT, None, "spam", None, None, None, {})])

    text = str(record.build_view(conn, "UM")["blocks"])

    assert "case 44" in text and "(<https://slack/44|Slack>)" in text


def test_build_view_reads_the_real_thread_of_each_action_case():
    conn = Conn(counts=(1, 0, 1, 0, 0), actions=[("shush", 44, "UMOD", AT, None, "spam", None, None, None, {})])

    record.build_view(conn, "UM")

    assert any(sql == record.channel.THREAD_FOR_CASE and args == {"case_id": 44} for sql, args in conn.executed)
