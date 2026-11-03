from jobs import imported_chat
from jobs.imported_chat import CHAT, SKIP
from jobs.shroud_identity import SHROUD_BOT_ID, SHROUD_BOT_USER_ID
from lyla.mapping import LYLA_BOT_USER_ID

THREAD = "1792777065.572749"


def message(ts="1792777100.000100", **over):
    one = {"ts": ts, "thread_ts": THREAD, "user": "UFIREFIGHTER", "text": "on it"}
    one.update(over)
    return one


def test_classify_skips_lyla_and_nemos_own_posts():
    assert imported_chat.classify(message(user=LYLA_BOT_USER_ID, text="Case #5053"), THREAD, 7, set()) == SKIP
    assert imported_chat.classify(message(user="UNEMO"), THREAD, 7, set(), {"UNEMO", "BNEMO"}) == SKIP
    assert imported_chat.classify(message(user=None, bot_id="BNEMO"), THREAD, 7, set(), {"UNEMO", "BNEMO"}) == SKIP


def test_classify_skips_anything_nemo_already_mirrored():
    assert imported_chat.classify(message(), THREAD, 7, {"1792777100.000100"}) == SKIP


def test_classify_skips_the_root_of_a_report_thread_and_keeps_other_roots():
    root = message(ts=THREAD, user=SHROUD_BOT_USER_ID, text="report text")

    assert imported_chat.classify(root, THREAD, 7, set()) == SKIP
    assert imported_chat.classify(message(ts=THREAD, text="the reported post"), THREAD, None, set()) == CHAT


def test_classify_keeps_shroud_relays_as_thread_chat():
    assert imported_chat.classify(message(user=SHROUD_BOT_USER_ID), THREAD, 7, set()) == CHAT
    assert imported_chat.classify(message(user=None, bot_id=SHROUD_BOT_ID), THREAD, 7, set()) == CHAT


def test_classify_keeps_firefighter_messages_and_skips_empty_ones():
    assert imported_chat.classify(message(), THREAD, 7, set()) == CHAT
    assert imported_chat.classify(message(text="", blocks=None), THREAD, 7, set()) == SKIP


def test_classify_keeps_file_only_messages():
    shot = message(user=SHROUD_BOT_USER_ID, text="", files=[{"id": "F1"}])

    assert imported_chat.classify(shot, THREAD, 7, set()) == CHAT


class Conn:
    def __init__(self, row=(901,)):
        self.row = row
        self.executed = []

    def execute(self, sql, args=None):
        self.executed.append((sql, args))
        return self

    def fetchone(self):
        return self.row

    def fetchall(self):
        return [("1.5",)]


def test_known_mirrors_checks_every_mirror_kind_in_one_query():
    conn = Conn()

    assert imported_chat.known_mirrors(conn, ["1.5", "1.6"]) == {"1.5"}
    sql, args = conn.executed[0]
    assert "intake_messages" in sql and "intake_outbox" in sql and "case_chat" in sql
    assert args == (["1.5", "1.6"],)
    assert imported_chat.known_mirrors(conn, []) == set()
