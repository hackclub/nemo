import contextlib
import datetime as dt

import pytest

from bot.core import merges
from bot.nemo import case_actions, case_queue, channel
from bot.nemo.surface import case_card as surface
from bot.nemo.views import lines

MOD = "UMOD"
RESOLVED_AT = dt.datetime(2026, 11, 2, 9, 30, tzinfo=dt.UTC)
REOPEN_REPORTS = "UPDATE fd.case_reports r"


class Conn:
    def __init__(self, one=None, many=None):
        self.one = one or {}
        self.many = many or {}
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def answer(self, rows):
        sql, args = self.executed[-1]
        value = rows.get(sql)
        return value(args) if callable(value) else value

    def fetchone(self):
        return self.answer(self.one)

    def fetchall(self):
        return self.answer(self.many) or []

    def ran(self, sql):
        return [args for statement, args in self.executed if statement == sql]

    def audits(self):
        return [(args[2], args[3], args[4], args[5] and args[5].obj, args[6] and args[6].obj)
                for sql, args in self.executed if "INSERT INTO fd.audit" in sql]


def merged_case(prior=(None, None), family=((25,),)):
    return Conn(
        one={
            merges.LOCK_CASE: (23, RESOLVED_AT, "duplicate"),
            merges.LIVE_MERGE: (9, 23, *prior),
            merges.UNMERGE: prior,
        },
        many={merges.FAMILY: list(family)},
    )


def test_unmerge_of_a_case_open_before_the_merge_opens_it_and_its_reports():
    conn = merged_case(family=[(25,), (40,)])

    assert merges.unmerge(conn, 25, MOD) == {"into_case_id": 23, "reopened": True, "removed_tags": []}

    assert conn.ran(merges.UNMERGE) == [(None, None, 25)]
    assert [args for sql, args in conn.executed if REOPEN_REPORTS in sql] == [(25,), (40,)]
    assert conn.audits() == [(
        "case", 25, "unmerged",
        {"resolved_at": str(RESOLVED_AT), "resolution": "duplicate", "duplicate_of": 23},
        {"resolved_at": None, "resolution": None, "duplicate_of": None},
    )]


def test_unmerge_of_a_case_resolved_before_the_merge_keeps_that_resolution():
    conn = merged_case(prior=(RESOLVED_AT, "no_action"))

    unmerged = merges.unmerge(conn, 25, MOD)

    assert unmerged["reopened"] is False
    assert conn.ran(merges.UNMERGE) == [(RESOLVED_AT, "no_action", 25)]
    assert not [sql for sql, _args in conn.executed if REOPEN_REPORTS in sql]
    assert conn.audits()[0][4] == {"resolved_at": str(RESOLVED_AT), "resolution": "no_action",
                                   "duplicate_of": None}


def test_unmerge_without_a_merge_record_opens_the_case():
    conn = merged_case()
    conn.one[merges.LIVE_MERGE] = None
    conn.one[merges.UNMERGE] = (None, None)

    assert merges.unmerge(conn, 25, MOD)["reopened"] is True
    assert conn.ran(merges.UNMERGE) == [(None, None, 25)]
    assert conn.ran(merges.COPIED_TAGS) == []


def test_unmerge_of_a_case_that_is_not_merged_changes_nothing():
    conn = Conn(one={merges.LOCK_CASE: (None, None, None)})

    assert merges.unmerge(conn, 25, MOD) is None
    assert conn.ran(merges.UNMERGE) == []


def test_unmerge_hands_copied_tags_to_another_merged_case_or_removes_them():
    conn = merged_case()
    conn.many[merges.COPIED_TAGS] = [(7, "scam"), (8, "spam")]
    conn.one[merges.TAG_KEEPER] = lambda args: (12,) if args[2] == 7 else None

    assert merges.unmerge(conn, 25, MOD)["removed_tags"] == ["spam"]

    assert conn.ran(merges.KEEP_TAG) == [(12, 23, 7)]
    assert conn.ran(merges.DROP_TAG) == [(23, 8)]
    assert ("case_tag", 23, "removed", {"tags": ["spam"], "source_case_ids": [25]}, None) in conn.audits()


def test_merge_of_a_case_merged_elsewhere_releases_its_old_tags_first():
    conn = Conn(one={
        case_actions.MERGE_STATE: (RESOLVED_AT, "duplicate", 30),
        case_actions.MERGE: (RESOLVED_AT,),
        merges.LIVE_MERGE: (4, 30, None, None),
    }, many={merges.COPIED_TAGS: [(8, "spam")]})

    assert case_actions.merge(conn, 23, [25], MOD) == [25]

    assert conn.ran(merges.DROP_TAG) == [(30, 8)]
    statements = [sql for sql, _args in conn.executed]
    assert statements.index(merges.DROP_TAG) < statements.index(case_actions.MERGE)


def test_merge_of_a_case_and_a_case_already_under_it_moves_only_the_parent():
    conn = Conn(one={
        case_actions.MERGE_STATE: (None, None, None),
        case_actions.MERGE: (RESOLVED_AT,),
    }, many={merges.FAMILY: lambda args: [(25,), (40,)] if args == (25,) else [args]})

    assert case_actions.merge(conn, 23, [40, 25], MOD) == [25]
    assert conn.ran(case_actions.MERGE) == [(23, 25)]


def test_reopen_of_a_merged_case_unmerges_it_first(monkeypatch):
    calls = []
    monkeypatch.setattr(merges, "unmerge", lambda conn, case_id, by: calls.append(case_id) or {"reopened": True})
    conn = Conn()

    assert case_actions.reopen(conn, 25, MOD) is True
    assert calls == [25]


def test_reopen_of_an_open_case_that_is_not_merged_does_nothing():
    assert case_actions.reopen(Conn(), 25, MOD) is False


def test_unmerged_lines_name_both_cases_in_both_threads():
    assert lines.unmerged(MOD, 25, 23, lambda case_id: f"https://fe/cases/{case_id}") == [
        (23, f"<@{MOD}> unmerged case <https://fe/cases/25|25> from case <https://fe/cases/23|23> (this case)"),
        (25, f"<@{MOD}> unmerged case <https://fe/cases/25|25> (this case) from case <https://fe/cases/23|23>"),
    ]


class Ctx:
    def __init__(self, case_id=25):
        self.body = {"actions": [{"value": str(case_id)}]}
        self.view = {}
        self.client = object()
        self.user_id = MOD
        self.ephemerals = []

    def post_ephemeral(self, message, channel_id=None, thread_ts=None):
        self.ephemerals.append(message)


@pytest.fixture
def card_world(monkeypatch):
    seen = {"refreshed": [], "said": [], "checked": [], "unmerged": [], "may": (True, None),
            "into": 23}

    @contextlib.contextmanager
    def session():
        yield Conn()

    def may(conn, user_id, key, case_id=None):
        seen["checked"].append((key, case_id))
        return seen["may"]

    def unmerge(conn, case_id, by):
        seen["unmerged"].append(case_id)
        return {"into_case_id": 23, "reopened": True, "removed_tags": []}

    monkeypatch.setattr(surface, "session", session)
    monkeypatch.setattr(surface.access, "may", may)
    monkeypatch.setattr(case_actions, "merged_into", lambda conn, case_id: seen["into"])
    monkeypatch.setattr(merges, "unmerge", unmerge)
    monkeypatch.setattr(channel, "refresh_card", lambda client, conn, case_id: seen["refreshed"].append(case_id))
    monkeypatch.setattr(case_queue, "refresh_card", lambda client, conn, case_id: None)
    monkeypatch.setattr(channel, "post_line", lambda client, conn, case_id, text: seen["said"].append(case_id))
    monkeypatch.setattr(channel, "case_url", lambda case_id: None)
    return seen


def test_unmerge_from_card_checks_both_cases_redraws_both_cards_and_posts_in_both_threads(card_world):
    assert surface.unmerge_from_card(Ctx()) == 25

    assert card_world["checked"] == [("case.resolve", 25), ("case.resolve", 23)]
    assert card_world["unmerged"] == [25]
    assert card_world["refreshed"] == [25, 23]
    assert card_world["said"] == [23, 25]


def test_unmerge_from_card_refused_on_either_case_is_private(card_world):
    card_world["may"] = (False, "You can't resolve this case")
    ctx = Ctx()

    surface.unmerge_from_card(ctx)

    assert ctx.ephemerals == ["You can't resolve this case"]
    assert card_world["unmerged"] == [] and card_world["said"] == []


def test_unmerge_from_card_on_a_case_that_is_not_merged_says_so(card_world):
    card_world["into"] = None
    ctx = Ctx()

    surface.unmerge_from_card(ctx)

    assert ctx.ephemerals == ["Case 25 is not merged"] and card_world["unmerged"] == []
