from contextlib import contextmanager
from types import SimpleNamespace

import pytest

from bot.core import audit
from bot.nemo.enforcement import purge

CHANNEL = "C1"
MEMBER = "U9"
PURGE_ID = 7


class Db:
    def __init__(self, channel_id=CHANNEL, member_id=None, wanted=3, state="asked", archived=(),
                 guard=None):
        self.purge = {"channel_id": channel_id, "member_id": member_id, "wanted": wanted,
                      "asked_by": "UASK", "state": state, "found": None, "error": None,
                      "left": None, "checked": False}
        self.items = {}
        self.archived = list(archived)
        self.audits = []
        self.guard = guard
        self.rows = []

    def execute(self, sql, args=None):
        handlers = {
            purge.CLAIM: self.claim, purge.ITEM_COUNT: self.item_count, purge.ENQUEUE_ITEMS: self.queue,
            purge.SET_FOUND: self.found, purge.NEXT_ITEMS: self.next, purge.MARK_ITEM: self.mark,
            purge.RECORD_ITEM: self.record_item, purge.UPDATE_PROGRESS: lambda _: [], purge.SET_CHECKING: self.checking,
            purge.DONE_ITEMS: self.done_items, purge.FINISH: self.finish,
            purge.ARCHIVED_MESSAGES: self.archive, purge.INTERRUPTED: self.interrupted, audit.RECORD: self.audit,
            purge.GUARD_STATE: lambda _: [self.guard] if self.guard else [],
        }
        self.rows = handlers[sql](args) or []
        return self

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return list(self.rows)

    def claim(self, _):
        if self.purge["state"] != "asked":
            return []
        self.purge["state"] = "running"
        p = self.purge
        return [(PURGE_ID, p["channel_id"], p["member_id"], p["wanted"], p["asked_by"])]

    def item_count(self, _):
        return [(len(self.items),)]

    def put(self, channel_id, ts, thread_ts=None, author_id=None, text=None, reply_count=None,
            state="queued", error=None):
        self.items[(channel_id, ts)] = {"channel_id": channel_id, "ts": ts, "thread_ts": thread_ts,
                                        "author_id": author_id, "text": text,
                                        "reply_count": reply_count, "state": state, "error": error}

    def queue(self, args):
        _, channels, tss, threads, authors, texts, replies = args
        for row in zip(channels, tss, threads, authors, texts, replies):
            if (row[0], row[1]) not in self.items:
                self.put(*row)

    def found(self, args):
        self.purge["found"] = args[0]

    def next(self, _):
        queued = [one for one in self.items.values() if one["state"] == "queued"]
        queued.sort(key=lambda one: (-float(one["thread_ts"] or one["ts"]),
                                     one["thread_ts"] is None, -float(one["ts"])))
        return [(one["channel_id"], one["ts"], one["thread_ts"], one["author_id"], one["text"],
                 one["reply_count"]) for one in queued[:purge.BATCH]]

    def mark(self, args):
        state, error, _, channel_id, ts = args
        self.items[(channel_id, ts)].update(state=state, error=error)

    def record_item(self, args):
        _, channel_id, ts, thread_ts, author_id, text, state, error = args
        if (channel_id, ts) in self.items:
            self.items[(channel_id, ts)].update(state=state, error=error)
        else:
            self.put(channel_id, ts, thread_ts, author_id, text, None, state, error)

    def checking(self, _):
        if self.purge["state"] == "running":
            self.purge["state"] = "checking"

    def done_items(self, _):
        return [(one["channel_id"], one["ts"], one["thread_ts"]) for one in self.items.values()]

    def finish(self, args):
        state, error, left, checked, _, _ = args
        if self.purge["state"] not in ("running", "checking"):
            return []
        self.purge.update(state=state, error=error, left=left, checked=checked)
        return [(self.count("deleted"),)]

    def archive(self, args):
        rows = [row for row in self.archived
                if args["channel_id"] is None or row[0] == args["channel_id"]]
        return rows[:args["limit"]]

    def interrupted(self, _):
        if self.purge["state"] not in ("running", "checking"):
            return []
        self.purge["state"] = "asked"
        return [(PURGE_ID,)]

    def audit(self, args):
        self.audits.append(args)

    def count(self, state):
        return sum(one["state"] == state for one in self.items.values())

    def state_of(self, ts, channel_id=CHANNEL):
        return self.items[(channel_id, ts)]["state"]


class Slack:
    def __init__(self):
        self.posts = []

    def chat_postMessage(self, **kwargs):
        self.posts.append(kwargs)


def message(ts, text="body a thing", user="U1", **over):
    return {"ts": ts, "user": user, "text": text, **over}


def parent(ts, replies=1, **over):
    return message(ts, thread_ts=ts, reply_count=replies, **over)


def match(channel_id, ts, user=MEMBER, text="said it", **where):
    return {"channel": {"id": channel_id, **where}, "ts": ts, "user": user, "text": text,
            "permalink": f"https://hackclub.slack.com/archives/{channel_id}/p{ts.replace('.', '')}"}


def search_page(matches, pages=1):
    return {"messages": {"matches": matches, "paging": {"pages": pages}}}


@pytest.fixture
def purge_env(monkeypatch):
    state = SimpleNamespace(db=Db(), pages=[], window=[], threads={}, search_rounds=[], search_round=[],
                            removed=[], failing=set(), already_deleted=set(), history_calls=[],
                            search_fails=False, allowed=True, capability_checks=[])

    @contextmanager
    def session():
        yield state.db

    def history(channel_id, cursor=None, limit=200, oldest=None, latest=None):
        state.history_calls.append({"cursor": cursor, "oldest": oldest, "latest": latest})
        if oldest is not None or latest is not None:
            return {"messages": state.window}
        return state.pages.pop(0) if state.pages else {"messages": []}

    def replies(channel_id, ts, cursor=None, limit=200):
        pending = state.threads.get(ts) or []
        return {"messages": [message(ts)] + (pending.pop(0) if pending else [])}

    def search(query, page=1, count=100):
        if state.search_fails:
            raise RuntimeError("search is down")
        if page == 1:
            state.search_round = state.search_rounds.pop(0) if state.search_rounds else []
        return state.search_round[page - 1] if page <= len(state.search_round) else search_page([], len(state.search_round))

    def remove(_client, channel_id, ts):
        if ts in state.failing:
            raise RuntimeError("cant_delete_message")
        if ts in state.already_deleted:
            raise RuntimeError("message_not_found")
        state.removed.append((channel_id, ts))

    def may(conn, user_id, key, case_id=None):
        state.capability_checks.append((user_id, key))
        return (True, None) if state.allowed else (False, "Community manager only")

    monkeypatch.setattr(purge, "session", session)
    monkeypatch.setattr(purge.access, "may", may)
    monkeypatch.setattr(purge.privileged, "history", history)
    monkeypatch.setattr(purge.privileged, "replies", replies)
    monkeypatch.setattr(purge.privileged, "search", search)
    monkeypatch.setattr(purge.guard_actions, "remove", remove)
    monkeypatch.setattr(purge.channel, "log_channel", lambda: "CLOG")
    monkeypatch.setattr(purge.channel, "app_url", lambda path: f"https://fd.test{path}")
    monkeypatch.setattr(purge.channel, "member_url", lambda user_id: f"https://fd.test/m/{user_id}")
    monkeypatch.setattr(purge, "CHECK_DELAY_SECONDS", 0)
    return state


def test_run_unclaimed_purge_returns_zero_without_deleting(purge_env):
    purge_env.db = Db(state="done")

    assert purge.run(Slack(), PURGE_ID) == 0
    assert purge_env.removed == []
    assert purge_env.db.audits == []


def test_run_requester_without_purge_access_fails_without_deleting(purge_env):
    purge_env.pages = [{"messages": [message("2"), message("1")]}]
    purge_env.allowed = False

    assert purge.run(Slack(), PURGE_ID) == 0
    assert purge_env.removed == []
    assert purge_env.db.purge["state"] == "failed"
    assert purge_env.db.purge["error"] == "<@UASK> no longer has purge access"


def test_run_checks_channel_purge_and_member_purge_capabilities(purge_env):
    purge_env.pages = [{"messages": [message("1")]}]
    purge.run(Slack(), PURGE_ID)
    purge_env.db = Db(channel_id=None, member_id=MEMBER, wanted=None)
    purge.run(Slack(), PURGE_ID)

    assert purge_env.capability_checks == [("UASK", "channel.purge"), ("UASK", "member.purge")]


def test_run_channel_purge_deletes_messages_newest_first(purge_env):
    purge_env.pages = [{"messages": [message("3"), message("2"), message("1")]}]

    assert purge.run(Slack(), PURGE_ID) == 3
    assert purge_env.removed == [(CHANNEL, "3"), (CHANNEL, "2"), (CHANNEL, "1")]
    assert purge_env.db.purge["state"] == "done"
    assert purge_env.db.purge["found"] == 3


def test_run_records_deleted_message_text_and_author(purge_env):
    purge_env.pages = [{"messages": [message("3", "the thing said")]}]
    purge.run(Slack(), PURGE_ID)

    item = purge_env.db.items[(CHANNEL, "3")]
    assert (item["text"], item["author_id"], item["state"]) == ("the thing said", "U1", "deleted")


def test_run_wanted_count_limits_deleted_messages(purge_env):
    purge_env.pages = [{"messages": [message(str(n)) for n in range(9, 0, -1)]}]
    purge.run(Slack(), PURGE_ID)

    assert purge_env.removed == [(CHANNEL, "9"), (CHANNEL, "8"), (CHANNEL, "7")]


def test_run_channel_join_message_is_not_deleted_or_counted(purge_env):
    purge_env.pages = [{"messages": [message("4"), message("3", subtype="channel_join"),
                                 message("2"), message("1")]}]
    purge.run(Slack(), PURGE_ID)

    assert purge_env.removed == [(CHANNEL, "4"), (CHANNEL, "2"), (CHANNEL, "1")]


def test_run_follows_history_cursor_until_wanted_count_reached(purge_env):
    purge_env.pages = [
        {"messages": [message("5")], "response_metadata": {"next_cursor": "more"}},
        {"messages": [message("4"), message("3")]},
    ]
    purge.run(Slack(), PURGE_ID)

    assert purge_env.history_calls[1]["cursor"] == "more"
    assert len(purge_env.removed) == 3


def test_run_without_wanted_deletes_every_message(purge_env):
    purge_env.db = Db(wanted=None)
    purge_env.pages = [{"messages": [message(str(n)) for n in range(9, 0, -1)]}]

    assert purge.run(Slack(), PURGE_ID) == 9


def test_run_thread_replies_deleted_before_parent_including_late_replies(purge_env):
    purge_env.pages = [{"messages": [parent("3", replies=1)]}]
    purge_env.threads = {"3": [[message("3.1")], [message("3.2")]]}
    purge.run(Slack(), PURGE_ID)

    assert purge_env.removed == [(CHANNEL, "3.1"), (CHANNEL, "3.2"), (CHANNEL, "3")]
    assert purge_env.db.items[(CHANNEL, "3.1")]["thread_ts"] == "3"
    assert purge_env.db.items[(CHANNEL, "3")]["thread_ts"] is None


def test_run_already_deleted_message_is_marked_gone_and_not_counted(purge_env):
    purge_env.pages = [{"messages": [message("2"), message("1")]}]
    purge_env.already_deleted = {"1"}

    assert purge.run(Slack(), PURGE_ID) == 1
    assert purge_env.db.state_of("1") == "gone"


def test_run_failed_delete_is_recorded_and_remaining_messages_are_deleted(purge_env):
    purge_env.pages = [{"messages": [message("3"), message("2"), message("1")]}]
    purge_env.failing = {"2"}

    assert purge.run(Slack(), PURGE_ID) == 2
    assert purge_env.db.state_of("2") == "failed"
    assert "cant_delete_message" in purge_env.db.items[(CHANNEL, "2")]["error"]
    assert purge_env.db.purge["state"] == "done"


def test_run_failures_in_a_row_over_limit_fails_purge(purge_env, monkeypatch):
    monkeypatch.setattr(purge, "FAILURES_IN_A_ROW", 2)
    purge_env.pages = [{"messages": [message("3"), message("2"), message("1")]}]
    purge_env.failing = {"3", "2", "1"}
    purge.run(Slack(), PURGE_ID)

    assert purge_env.db.purge["state"] == "failed"
    assert "failed in a row" in purge_env.db.purge["error"]


def test_run_messages_over_cap_fails_purge(purge_env, monkeypatch):
    monkeypatch.setattr(purge, "CAP", 2)
    purge_env.pages = [{"messages": [parent("3")]}]
    purge_env.threads = {"3": [[message("3.1"), message("3.2"), message("3.3")]]}
    purge.run(Slack(), PURGE_ID)

    assert purge_env.db.purge["state"] == "failed"
    assert "more than 2" in purge_env.db.purge["error"]


def test_run_check_deletes_messages_still_in_history_window(purge_env):
    purge_env.pages = [{"messages": [message("3"), message("2"), message("1")]}]
    purge_env.window = [message("2"), message("9", subtype="channel_join")]
    purge.run(Slack(), PURGE_ID)

    assert purge_env.history_calls[-1]["oldest"] == "1"
    assert purge_env.history_calls[-1]["latest"] == "3"
    assert purge_env.removed.count((CHANNEL, "2")) == 2
    assert purge_env.db.purge["left"] == 0
    assert purge_env.db.purge["checked"] is True


def test_run_check_failed_deletes_are_counted_as_left(purge_env, monkeypatch):
    purge_env.pages = [{"messages": [message("2"), message("1")]}]
    purge_env.window = [message("2")]

    def fail_on_repeat_delete(_client, channel_id, ts):
        if (channel_id, ts) in purge_env.removed:
            raise RuntimeError("cant_delete_message")
        purge_env.removed.append((channel_id, ts))

    monkeypatch.setattr(purge.guard_actions, "remove", fail_on_repeat_delete)
    purge.run(Slack(), PURGE_ID)

    assert purge_env.db.purge["left"] == 1


def test_run_member_purge_deletes_archived_and_searched_messages(purge_env):
    purge_env.db = Db(channel_id=None, member_id=MEMBER, wanted=None,
                  archived=[("C1", "5.0", None), ("C2", "4.0", "3.9")])
    purge_env.search_rounds = [[search_page([
        match("C3", "6.0", text="from search"),
        match("C1", "5.0", text="the words"),
        match("D1", "7.0", is_im=True),
        match("C4", "8.0", user="USOMEONE"),
    ])]]

    assert purge.run(Slack(), PURGE_ID) == 3
    assert purge_env.removed == [("C3", "6.0"), ("C1", "5.0"), ("C2", "4.0")]
    assert purge_env.db.items[("C1", "5.0")]["text"] == "the words"
    assert purge_env.db.items[("C2", "4.0")]["thread_ts"] == "3.9"


def test_run_member_purge_with_channel_deletes_only_in_that_channel(purge_env):
    purge_env.db = Db(channel_id="C1", member_id=MEMBER, wanted=None,
                  archived=[("C1", "5.0", None), ("C2", "4.0", None)])
    purge_env.search_rounds = [[search_page([match("C1", "6.0"), match("C3", "7.0")])]]
    purge.run(Slack(), PURGE_ID)

    assert purge_env.removed == [("C1", "6.0"), ("C1", "5.0")]


def test_run_member_purge_wanted_count_limits_archived_messages(purge_env):
    purge_env.db = Db(channel_id=None, member_id=MEMBER, wanted=2,
                  archived=[("C1", "5.0", None), ("C2", "4.0", None), ("C2", "3.0", None)])
    purge.run(Slack(), PURGE_ID)

    assert purge_env.removed == [("C1", "5.0"), ("C2", "4.0")]


def test_run_member_check_deletes_messages_found_by_search(purge_env):
    purge_env.db = Db(channel_id=None, member_id=MEMBER, wanted=None,
                  archived=[("C1", "5.0", None)])
    purge_env.search_rounds = [[search_page([])], [search_page([match("C2", "6.0", text="posted late")])]]
    purge.run(Slack(), PURGE_ID)

    assert purge_env.removed == [("C1", "5.0"), ("C2", "6.0")]
    assert purge_env.db.items[("C2", "6.0")]["text"] == "posted late"
    assert purge_env.db.purge["left"] == 0


def test_run_member_purge_search_failure_still_deletes_archived_messages(purge_env):
    purge_env.db = Db(channel_id=None, member_id=MEMBER, wanted=None,
                  archived=[("C1", "5.0", None)])
    purge_env.search_fails = True
    purge.run(Slack(), PURGE_ID)

    assert purge_env.removed == [("C1", "5.0")]
    assert purge_env.db.purge["state"] == "done"
    assert purge_env.db.purge["left"] is None
    assert purge_env.db.purge["error"] == "check failed: search is down"


def test_run_with_existing_items_skips_history_collection(purge_env):
    purge_env.db.put(CHANNEL, "2", author_id="U1", text="queued before the restart")
    purge_env.db.put(CHANNEL, "1", state="deleted")
    purge.run(Slack(), PURGE_ID)

    assert [call for call in purge_env.history_calls if call["oldest"] is None] == []
    assert purge_env.removed[0] == (CHANNEL, "2")


def test_requeue_interrupted_running_purge_returns_purge_id_and_resets_state(purge_env):
    purge_env.db = Db(state="running")

    assert purge.requeue_interrupted(purge_env.db) == [PURGE_ID]
    assert purge_env.db.purge["state"] == "asked"


def test_run_posts_summary_and_records_channel_purge_audit(purge_env):
    purge_env.pages = [{"messages": [message("2"), message("1")]}]
    slack = Slack()
    purge.run(slack, PURGE_ID)

    [post] = slack.posts
    assert post["channel"] == "CLOG"
    assert post["text"].startswith("2 messages deleted in <#C1> by <@UASK>.")
    assert "https://fd.test/fd/channels/C1/purges/7" in post["text"]
    [row] = purge_env.db.audits
    assert (row[2], row[3], row[4]) == ("channel_purge", PURGE_ID, "performed")


def test_run_member_purge_records_audit_with_member_subject(purge_env):
    purge_env.db = Db(channel_id=None, member_id=MEMBER, wanted=None, archived=[("C1", "5.0", None)])
    slack = Slack()
    purge.run(slack, PURGE_ID)

    [row] = purge_env.db.audits
    assert (row[2], row[4], row[8]) == ("member_purge", "performed", MEMBER)
    assert slack.posts[0]["text"].startswith("1 message from <@U9> deleted in every channel by <@UASK>.")
    assert "https://fd.test/fd/members/U9/purges/7" in slack.posts[0]["text"]


def test_summary_appends_left_stopped_and_check_failed_details():
    channel_purge = purge.Purge(7, "C1", None, 50, "UASK")

    assert purge.summary(channel_purge, 17, 0, None).startswith(
        "17 messages deleted in <#C1> by <@UASK>.")
    assert purge.summary(channel_purge, 17, 2, None).startswith(
        "17 messages deleted in <#C1> by <@UASK>, 2 left after the check.")
    assert purge.summary(channel_purge, 3, None, "slack is down").startswith(
        "3 messages deleted in <#C1> by <@UASK>, stopped: slack is down.")
    assert purge.summary(channel_purge, 3, None, None, "search is down").startswith(
        "3 messages deleted in <#C1> by <@UASK>, check failed: search is down.")


def deactivation_purge(guard):
    return Db(channel_id=None, member_id=MEMBER, wanted=None, archived=[("C1", "5.0", None)],
              guard=guard)


def test_run_with_pending_deactivation_defers_purge_without_deleting(purge_env):
    purge_env.db = deactivation_purge(("live", "pending"))

    assert purge.run(Slack(), PURGE_ID) == 0
    assert purge_env.removed == []
    assert purge_env.db.purge["state"] == "asked"


def test_run_with_enforced_deactivation_deletes_archived_messages(purge_env):
    purge_env.db = deactivation_purge(("live", "held"))

    assert purge.run(Slack(), PURGE_ID) == 1
    assert purge_env.removed == [("C1", "5.0")]


def test_run_with_lifted_deactivation_fails_without_deleting(purge_env):
    purge_env.db = deactivation_purge(("lifted", "pending"))
    purge.run(Slack(), PURGE_ID)

    assert purge_env.removed == []
    assert purge_env.db.purge["state"] == "failed"
    assert purge_env.db.purge["error"] == purge.DEACTIVATION_LIFTED


def test_run_with_cancelled_deactivation_fails_without_deleting(purge_env):
    purge_env.db = deactivation_purge(("cancelled", "pending"))
    purge.run(Slack(), PURGE_ID)

    assert purge_env.removed == []
    assert purge_env.db.purge["state"] == "failed"
    assert purge_env.db.purge["error"] == purge.DEACTIVATION_CANCELLED


def test_queued_purges_sql_releases_purges_of_cancelled_deactivations():
    assert "g.state IN ('lifted', 'cancelled')" in purge.QUEUED_PURGES
