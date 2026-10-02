from bot.shroud.carrier import Carrier, shared_at

ROOM = "D123"
THREAD = "100.000"


class Slack:
    def __init__(self, info=None, replies=None):
        self.info = info or {}
        self.replies = replies or {}
        self.asked = []

    def files_info(self, file):
        self.asked.append("files.info")
        if not self.info:
            raise RuntimeError("no_file_info")
        return self.info

    def conversations_replies(self, channel, ts, limit):
        self.asked.append("conversations.replies")
        return self.replies


def shared(ts):
    return {"shares": {"private": {ROOM: [{"ts": ts}]}}}


def test_the_upload_answer_is_used_when_it_names_the_share():
    slack = Slack()
    one = Carrier(slack)
    found = one.where_it_landed(dict(shared("1.1"), id="F1"), ROOM, THREAD)
    assert found == "1.1"
    assert slack.asked == [], "no need to ask twice when the upload already said"


def test_files_info_is_asked_when_the_upload_says_nothing():
    slack = Slack(info={"file": shared("2.2")})
    found = Carrier(slack).where_it_landed({"id": "F1"}, ROOM, THREAD)
    assert found == "2.2"
    assert slack.asked == ["files.info"]


def test_the_thread_settles_it_when_slack_will_not():
    slack = Slack(replies={"messages": [
        {"ts": "3.0", "files": [{"id": "OTHER"}]},
        {"ts": "3.3", "files": [{"id": "F1"}]},
    ]})
    found = Carrier(slack).where_it_landed({"id": "F1"}, ROOM, THREAD)
    assert found == "3.3", "the message carrying our file is the message it made"
    assert slack.asked == ["files.info", "conversations.replies"]


def test_a_file_nobody_can_place_is_not_guessed_at():
    slack = Slack(replies={"messages": [{"ts": "4.0", "files": [{"id": "OTHER"}]}]})
    assert Carrier(slack).where_it_landed({"id": "F1"}, ROOM, THREAD) is None


def test_an_upload_with_no_id_is_left_alone():
    slack = Slack()
    assert Carrier(slack).where_it_landed({}, ROOM, THREAD) is None
    assert slack.asked == []


def test_shared_at_ignores_another_room():
    assert shared_at({"shares": {"private": {"D999": [{"ts": "9.9"}]}}}, ROOM) is None
