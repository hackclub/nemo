import pytest

from bot.nemo.views import action, edit

USER_ID = "U1"
MOD = "UMOD"


@pytest.fixture(autouse=True)
def categories(monkeypatch):
    monkeypatch.setattr(edit, "categories", lambda: {"adult": "Adult", "spam": "Spam"})


def ids(blocks):
    return [one.get("block_id") for one in blocks]


def submission(**over):
    row = {"type_key": "perma_ban", "target_user_id": USER_ID, "reason": "", "category_key": "adult"}
    row.update(over)
    return row


def test_build_blocks_adult_category_omits_reason():
    built = action.build_blocks(412, submission())

    assert action.REASON not in ids(built)


def test_build_blocks_other_category_keeps_reason():
    built = action.build_blocks(412, submission(category_key="spam"))

    assert action.REASON in ids(built)


def test_build_blocks_category_select_dispatches_action():
    built = action.build_blocks(412, submission())
    category = next(one for one in built if one.get("block_id") == action.CATEGORY)

    assert category["dispatch_action"] is True


def test_validation_errors_adult_without_reason_passes():
    assert action.validation_errors(submission()) is None


def test_validation_errors_other_category_without_reason_asks_for_reason():
    assert action.validation_errors(submission(category_key="spam")) == {action.REASON: "Add a reason."}


def test_requires_refresh_when_reason_block_missing_for_reasoned_category():
    block_ids = set(ids(action.build_blocks(412, submission())))

    assert action.requires_refresh(submission(category_key="spam"), block_ids) is True


def test_guard_reason_without_reason_uses_category_label():
    assert action.guard_reason(submission()) == "Adult"
    assert action.guard_reason(submission(reason="over 18")) == "over 18"


def test_log_blocks_without_reason_has_no_quote():
    built = action.log_blocks(submission(type_key="warning"), MOD)

    assert [one["type"] for one in built] == ["header", "context"]
