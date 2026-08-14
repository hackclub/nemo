import json
import random
from dataclasses import dataclass
from datetime import date

from seed import conduct

AS_OF = date(2026, 8, 14)


@dataclass
class FakeMember:
    user_id: str
    engagement: float
    is_bot: bool = False


def crowd(size=12):
    return [FakeMember(user_id=f"USEED{n:07d}", engagement=1.0 - (n / size)) for n in range(size)]


def rows_for(members, stream="grants"):
    return conduct.access_grants(random.Random(stream), members, AS_OF)


def test_the_busiest_members_get_the_grants_and_the_first_two_lead():
    rows = rows_for(crowd())
    crew = conduct.firefighters(crowd())

    assert [row[0] for row in rows[: len(crew)]] == crew
    assert [row[1] for row in rows[: len(crew)]] == ["lead", "lead"] + ["firefighter"] * 3


def test_nobody_gives_themselves_access():
    for user_id, _role, _reason, giver, _at, _by, _ended in rows_for(crowd()):
        assert giver != user_id


def test_every_grant_is_given_by_somebody_who_holds_one():
    rows = rows_for(crowd())
    held = {row[0] for row in rows if row[6] is None}

    assert {row[3] for row in rows} <= held


def test_one_grant_is_left_dormant_and_one_is_ended():
    rows = rows_for(crowd())
    live = [row for row in rows if row[6] is None]
    ended = [row for row in rows if row[6] is not None]

    assert len(live) == conduct.FIREFIGHTER_COUNT + 1
    assert len(ended) == 1
    assert ended[0][5] is not None
    assert ended[0][6] > ended[0][4]


def test_a_crew_of_one_still_grants_without_a_giver_to_borrow():
    rows = rows_for(crowd(size=1))

    assert [row[0] for row in rows] == ["USEED0000000"]
    assert rows[0][3] == "USEED0000000"


def test_no_grants_without_members():
    assert conduct.access_grants(random.Random("grants"), [], AS_OF) == []


def test_refusals_only_land_on_the_firefighters_and_name_a_permission():
    rows = list(conduct.refusal_rows(random.Random("refusals"), crowd(), AS_OF))
    crew = conduct.firefighters(crowd())

    assert rows
    for row in rows:
        assert row[1] in crew[conduct.LEAD_COUNT :]
        assert row[5] == "refused"
        assert json.loads(row[7])["permission"] in conduct.REFUSED_KEYS
