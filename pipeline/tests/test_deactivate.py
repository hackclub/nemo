import pathlib

import pytest

from bot.nemo import memberguards
from bot.nemo.enforcement import deactivate

USER_ID = "U1"


class Conn:
    def __init__(self, lift_returns_row=True, action_returns_row=True):
        self.lift_returns_row = lift_returns_row
        self.action_returns_row = action_returns_row
        self.statements = []

    def execute(self, sql, args=None):
        self.statements.append((sql, args))
        return self

    def fetchone(self):
        sql, _ = self.statements[-1]
        if "JOIN fd.actions" in sql:
            return (7, memberguards.DEACTIVATION) if self.action_returns_row else None
        if "SET state = 'lifted'" in sql:
            return (7,) if self.lift_returns_row else None
        return (7,)

    def args_for(self, mark):
        return [args for sql, args in self.statements if mark in sql]

    def executed(self, mark):
        return any(mark in sql for sql, _ in self.statements)


class Slack:
    pass


def guard(**over):
    row = {"id": 7, "kind": "deactivation", "subject_id": USER_ID, "channel_id": None,
           "reason": "raiding", "expires_at": None}
    row.update(over)
    return row


@pytest.fixture
def slack_outcome(monkeypatch):
    def set_outcome(outcome):
        monkeypatch.setattr(deactivate.privileged, "deactivate", lambda user_id, conn=None: outcome)
        monkeypatch.setattr(deactivate.privileged, "reactivate", lambda user_id, conn=None: outcome)
    return set_outcome


def test_enforce_deactivated_outcome_marks_enforced_and_records_event(slack_outcome):
    slack_outcome("deactivated")
    conn = Conn()
    assert deactivate.enforce(Slack(), conn, guard())

    assert conn.executed("enforcement_status = 'held'")
    row = conn.args_for("INSERT INTO fd.member_guard_events")[0]
    assert row[3] == "deactivated"
    assert row[6] == "deactivated"


def test_enforce_failed_outcome_marks_failed_and_returns_false(slack_outcome):
    slack_outcome("failed: user_not_found")
    conn = Conn()
    assert not deactivate.enforce(Slack(), conn, guard())

    assert conn.executed("enforcement_status = 'failed'")
    assert not conn.executed("enforcement_status = 'held'")
    assert conn.args_for("INSERT INTO fd.member_guard_events")[0][3] == "failed"


@pytest.mark.parametrize("how", ["off", "would"])
def test_enforce_unarmed_outcome_marks_enforced(slack_outcome, how):
    slack_outcome(how)
    conn = Conn()
    assert deactivate.enforce(Slack(), conn, guard())
    assert conn.executed("enforcement_status = 'held'")
    assert conn.args_for("enforcement_status = 'held'") == [(True, 7)]


def test_enforce_deactivated_outcome_is_not_a_dry_run(slack_outcome):
    slack_outcome("deactivated")
    conn = Conn()
    deactivate.enforce(Slack(), conn, guard())

    assert conn.args_for("enforcement_status = 'held'") == [(False, 7)]


def test_lift_reactivated_outcome_marks_lifted_and_records_event(slack_outcome):
    slack_outcome("reactivated")
    conn = Conn()
    assert deactivate.lift(Slack(), conn, guard())

    assert conn.executed("state = 'lifted'")
    assert conn.args_for("INSERT INTO fd.member_guard_events")[0][3] == "reactivated"


def test_lift_failed_outcome_returns_false_without_lifted_state(slack_outcome):
    slack_outcome("failed: rate limited")
    conn = Conn()
    assert not deactivate.lift(Slack(), conn, guard())

    assert not conn.executed("state = 'lifted'")
    assert conn.args_for("INSERT INTO fd.member_guard_events")[0][3] == "failed"


def test_lift_already_lifted_guard_writes_no_event(slack_outcome):
    slack_outcome("reactivated")
    conn = Conn(lift_returns_row=False)
    assert deactivate.lift(Slack(), conn, guard())
    assert conn.args_for("INSERT INTO fd.member_guard_events") == []


def test_lifts_in_slack_true_only_for_deactivation():
    assert memberguards.lifts_in_slack(memberguards.DEACTIVATION)
    assert not memberguards.lifts_in_slack(memberguards.SHUSH)
    assert not memberguards.lifts_in_slack(memberguards.CHANNEL_BAN)


def test_loop_source_drains_still_lifting_guards_on_wake():
    from bot.nemo import loop

    loop_source = pathlib.Path(loop.__file__).read_text()
    assert "still_lifting" in loop_source, "the listener must drain what is lifting"
    assert "lambda: apply_pending_guards(case_channel.client)" in loop_source
    assert "wake_member_guards()" in loop_source


def test_migration_0140_allows_deactivation_kind_and_events():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0140_deactivation_guards.sql").read_text()
    assert "'shush', 'channel_ban', 'deactivation'" in sql
    assert "'deactivated', 'reactivated'" in sql
