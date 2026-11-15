import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from bot.nemo import surface
from bot.nemo.surface import end_row
from bot.nemo.views import action, edit, guard, slowmode

EXPIRES_AT = dt.datetime(2026, 11, 1, 12, 0, tzinfo=dt.UTC)
CURRENT_LOCK = {"expires_at": EXPIRES_AT, "reason": "enough", "opened_by": "UMOD"}


def picker_ids(view):
    return {
        element["action_id"]
        for block in view["blocks"] if block["type"] == "actions"
        for element in block["elements"] if element["type"] in ("datepicker", "timepicker")
    }


def action_view():
    return action.build_view(1, ["USUBJECT"], values={"type_key": "temp_ban"})


VIEW_BUILDERS = [
    lambda: guard.lock_view("C1", "1.1"),
    lambda: guard.locked_view("C1", "1.1", CURRENT_LOCK),
    lambda: slowmode.build_view("C1", None),
    action_view,
]


def time_zones(view):
    return [
        element.get("timezone")
        for block in view["blocks"] if block["type"] == "actions"
        for element in block["elements"] if element["type"] == "timepicker"
    ]


ZONED_BUILDERS = [
    lambda tz: guard.lock_view("C1", "1.1", tz=tz),
    lambda tz: guard.locked_view("C1", "1.1", CURRENT_LOCK, tz),
    lambda tz: slowmode.build_view("C1", None, tz=tz),
    lambda tz: action.build_view(1, ["USUBJECT"], values={"type_key": "temp_ban"}, timezone=tz.key),
]


@pytest.mark.parametrize("build", ZONED_BUILDERS)
def test_every_time_picker_shows_the_viewer_zone(build, monkeypatch):
    monkeypatch.setattr(edit, "categories", lambda: {"spam": "Spam"})

    assert time_zones(build(ZoneInfo("Africa/Cairo"))) == ["Africa/Cairo"]


@pytest.mark.parametrize("build", VIEW_BUILDERS)
def test_every_picker_in_a_modal_has_a_handler(build, monkeypatch):
    monkeypatch.setattr(edit, "categories", lambda: {"spam": "Spam"})

    ids = picker_ids(build())

    assert ids and ids <= set(end_row.PICKER_ACTION_IDS)


def test_picker_ids_cover_date_and_time_for_each_modal():
    assert len(set(end_row.PICKER_ACTION_IDS)) == 6


def registered(action_id):
    return [one for one in surface.ENTRIES if one.kind == surface.ACTION and one.key == action_id]


@pytest.mark.parametrize("action_id", end_row.PICKER_ACTION_IDS)
def test_picker_action_is_registered_open_to_all(action_id):
    entries = registered(action_id)

    assert len(entries) == 1 and entries[0].open_to_all


@pytest.mark.parametrize("action_id", end_row.PICKER_ACTION_IDS)
def test_picker_action_acknowledges_and_does_nothing(action_id):
    acked = []
    entry = registered(action_id)[0]

    result = surface.guarded(entry)(ack=lambda **kwargs: acked.append(kwargs), body={"user": {"id": "UMOD"}}, client=None)

    assert acked == [{}] and result is None
