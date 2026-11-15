import pytest

from bot.nemo import card_facts, case_cards, channel, case_queue
from bot.nemo.views import case_card


class Conn:
    def __init__(self, posted=()):
        self.posted = list(posted)
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchall(self):
        return self.posted

    def args_for(self, mark):
        return [args for sql, args in self.executed if mark in sql]


class Slack:
    def __init__(self, update_error=None, post_error=None):
        self.posts = []
        self.updates = []
        self.update_error = update_error
        self.post_error = post_error

    def chat_postMessage(self, **kwargs):
        if self.post_error:
            raise self.post_error
        self.posts.append(kwargs)
        return {"ts": "5.5"}

    def chat_update(self, **kwargs):
        if self.update_error:
            raise self.update_error
        self.updates.append(kwargs)


def case(**over):
    row = {"case_id": 39, "subjects": ["USUBJECT"], "assignees": [], "category_key": None,
           "resolved_at": None, "resolution": None}
    row.update(over)
    return row


@pytest.fixture
def loaded(monkeypatch):
    state = {"case": case()}
    monkeypatch.setattr(channel, "fetch_case", lambda conn, case_id: state["case"])
    monkeypatch.setattr(case_queue, "fetch_case", lambda conn, case_id: None)
    monkeypatch.setattr(card_facts, "enrich", lambda client, conn, row, url_of=None, thread_of=None: row)
    return state


def test_post_sends_card_in_thread_records_it_and_prunes(loaded):
    conn, slack = Conn(), Slack()

    assert case_cards.post(slack, conn, 39, "C1", "1.1", "UME") == "5.5"

    sent = slack.posts[0]
    assert sent["channel"] == "C1" and sent["thread_ts"] == "1.1"
    assert sent["blocks"][0]["type"] == "card"
    assert conn.args_for("INSERT INTO fd.case_card_posts")[0] == (
        39, "C1", "5.5", case_card.digest(loaded["case"]), "UME")
    assert conn.args_for("DELETE FROM fd.case_card_posts")[0] == (39, 39, case_cards.KEPT_PER_CASE)


def test_post_for_unknown_case_or_failed_send_records_nothing(loaded):
    conn = Conn()
    loaded["case"] = None
    assert case_cards.post(Slack(), conn, 39, "C1", "1.1") is None

    loaded["case"] = case()
    assert case_cards.post(Slack(post_error=RuntimeError("invalid_blocks")), conn, 39, "C1", "1.1") is None
    assert conn.executed == []


def test_refresh_edits_cards_whose_digest_is_stale(loaded):
    fresh = case_card.digest(loaded["case"])
    conn = Conn(posted=[(1, "C1", "2.2", "old"), (2, "C2", "3.3", fresh)])
    slack = Slack()

    assert case_cards.refresh(slack, conn, 39) == 1

    assert [(one["channel"], one["ts"]) for one in slack.updates] == [("C1", "2.2")]
    assert conn.args_for("SET digest")[0] == (fresh, 1)


def test_refresh_without_posted_cards_loads_nothing(loaded, monkeypatch):
    monkeypatch.setattr(case_cards, "load", lambda *args: pytest.fail("loaded"))

    assert case_cards.refresh(Slack(), Conn(), 39) == 0


def test_refresh_forgets_deleted_messages_and_raises_other_errors(loaded):
    conn = Conn(posted=[(1, "C1", "2.2", "old")])

    assert case_cards.refresh(Slack(update_error=RuntimeError("message_not_found")), conn, 39) == 0
    assert conn.args_for("DELETE FROM fd.case_card_posts WHERE id")[0] == (1,)

    with pytest.raises(RuntimeError):
        case_cards.refresh(Slack(update_error=RuntimeError("ratelimited")), Conn(posted=[(1, "C1", "2.2", "old")]), 39)
