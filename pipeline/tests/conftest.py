import pytest

from lib import calendar


@pytest.fixture(autouse=True)
def fresh_calendar():
    calendar.clear()
    yield
    calendar.clear()
