import pytest

from bot.nemo import card_facts, case_queue, channel
from bot.nemo.views import case_card


class Conn:
    def __init__(self):
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        return None

    def fetchall(self):
        return []

    def args_for(self, mark):
        return [args for sql, args in self.executed if mark in sql]


class Slack:
    def __init__(self, update_error=None):
        self.updates = []
        self.posts = []
        self.update_error = update_error

    def chat_update(self, **kwargs):
        if self.update_error:
            raise self.update_error
        self.updates.append(kwargs)
        return {"ok": True}

    def chat_postMessage(self, **kwargs):
        self.posts.append(kwargs)
        return {"ts": "7.7"}


@pytest.fixture(autouse=True)
def no_facts(monkeypatch):
    monkeypatch.setattr(card_facts, "enrich", lambda client, conn, case, url_of=None: case)


def report_case(**over):
    row = {"case_id": 49, "report_id": 3, "forwarded_ts": "1.1", "header_ts": "2.2", "header_digest": None,
           "body": "they spammed", "subjects": ["USUBJECT"], "assignees": [], "category_key": None,
           "resolved_at": None, "resolution": None}
    row.update(over)
    return row


def queue_case(**over):
    row = {"case_id": 49, "card_ts": "1.1", "card_channel_id": "C1", "card_thread_ts": None,
           "card_header_ts": "2.2", "card_header_digest": None, "body": "kept posting", "subjects": ["USUBJECT"],
           "assignees": [], "category_key": None, "resolved_at": None, "resolution": None}
    row.update(over)
    return row


def test_report_header_edits_reply_when_digest_differs():
    conn, slack = Conn(), Slack()
    case = report_case(assignees=["UMOD"])

    assert channel.sync_header(slack, conn, case, "C1") == "2.2"

    assert slack.updates[0]["ts"] == "2.2" and slack.updates[0]["channel"] == "C1"
    assert slack.updates[0]["blocks"][0]["type"] == "card"
    assert "metadata" not in slack.updates[0]
    assert conn.args_for("SET header_digest")[0] == (case_card.digest(case), 3)


def test_report_header_untouched_when_digest_matches():
    conn, slack = Conn(), Slack()
    case = report_case()
    case["header_digest"] = case_card.digest(case)

    channel.sync_header(slack, conn, case, "C1")

    assert slack.updates == [] and conn.executed == []


def test_report_header_posted_in_card_thread_when_missing():
    conn, slack = Conn(), Slack()

    ts = channel.sync_header(slack, conn, report_case(header_ts=None), "C1")

    assert ts == "7.7"
    assert slack.posts[0]["thread_ts"] == "1.1"
    assert conn.args_for("SET header_ts")[0][0] == "7.7"


def test_report_without_body_edits_the_card_itself():
    conn, slack = Conn(), Slack()

    channel.sync_header(slack, conn, report_case(body="", header_ts=None), "C1")

    assert slack.updates[0]["ts"] == "1.1"
    assert slack.updates[0]["metadata"]["event_type"] == "fd_case_card"
    assert slack.posts == []


def test_report_header_keeps_slack_message_when_edit_refused():
    conn = Conn()
    slack = Slack(update_error=RuntimeError("cant_update_message"))

    channel.sync_header(slack, conn, report_case(), "C1")

    assert conn.args_for("SET header_digest")


def test_report_header_raises_other_update_errors():
    with pytest.raises(RuntimeError):
        channel.sync_header(Slack(update_error=RuntimeError("ratelimited")), Conn(), report_case(), "C1")


def test_queue_header_edits_reply_when_digest_differs():
    conn, slack = Conn(), Slack()
    case = queue_case(assignees=["UMOD"])

    assert case_queue.sync_header(slack, conn, case) == "2.2"

    assert slack.updates[0]["ts"] == "2.2" and slack.updates[0]["channel"] == "C1"
    assert conn.args_for("SET card_header_digest")[0] == (case_card.digest(case), 49)


def test_queue_header_untouched_when_digest_matches():
    conn, slack = Conn(), Slack()
    case = queue_case()
    case["card_header_digest"] = case_card.digest(case)

    case_queue.sync_header(slack, conn, case)

    assert slack.updates == [] and conn.executed == []


def test_queue_header_posted_when_missing_and_skipped_inside_a_thread():
    conn, slack = Conn(), Slack()

    assert case_queue.sync_header(slack, conn, queue_case(card_header_ts=None)) == "7.7"
    assert case_queue.sync_header(slack, conn, queue_case(card_header_ts=None, card_thread_ts="9.9")) is None
    assert len(slack.posts) == 1


def test_queue_without_opening_edits_the_card_itself():
    conn, slack = Conn(), Slack()

    case_queue.sync_header(slack, conn, queue_case(body=None, card_header_ts=None))

    assert slack.updates[0]["ts"] == "1.1"


def test_report_card_metadata_names_the_reporter_unless_anonymous():
    conn, slack = Conn(), Slack()

    channel.sync_header(slack, conn, report_case(body="", header_ts=None, reporter_user_id="UREP"), "C1")
    channel.sync_header(slack, conn, report_case(body="", header_ts=None, reporter_user_id="UREP",
                                                 is_anonymous=True), "C1")

    assert slack.updates[0]["metadata"]["event_payload"]["source_user_id"] == "UREP"
    assert "source_user_id" not in slack.updates[1]["metadata"]["event_payload"]


def test_queue_card_metadata_names_whoever_opened_it():
    conn, slack = Conn(), Slack()

    case_queue.sync_header(slack, conn, queue_case(body=None, card_header_ts=None, opening_id=5, opened_by="UOPEN"))
    case_queue.sync_header(slack, conn, queue_case(body=None, card_header_ts=None, opening_id=None, opened_by="UOPEN"))

    assert slack.updates[0]["metadata"]["event_payload"]["source_user_id"] == "UOPEN"
    assert "source_user_id" not in slack.updates[1]["metadata"]["event_payload"]
