from datetime import UTC, datetime, timedelta

from ingest import access_logs_pull
from lib import archive, member_seen

EARLY = datetime(2026, 10, 1, 9, 0, tzinfo=UTC)
LATE = EARLY + timedelta(hours=5)


class Conn:
    def __init__(self):
        self.ran = []

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        return self

    def executemany(self, sql, rows):
        self.ran.append((sql, rows))

    def fetchall(self):
        return []

    def commit(self):
        pass

    def seen(self):
        return [args for sql, args in self.ran if "fd.member_seen" in sql]


class Counts:
    rows_in = 0
    rows_rejected = 0


def test_one_row_per_member_at_their_newest_time():
    pairs = [("U2", EARLY), ("U1", LATE), ("U2", LATE), ("U1", EARLY)]

    assert member_seen.latest(pairs) == [("U1", LATE), ("U2", LATE)]


def test_a_pair_without_a_member_or_a_time_is_dropped():
    assert member_seen.latest([("", LATE), (None, LATE), ("U1", None)]) == []


def test_nothing_to_say_writes_nothing():
    conn = Conn()
    member_seen.posted(conn, [])
    member_seen.logged_in(conn, [("U1", None)])

    assert conn.ran == []


def test_one_statement_carries_the_whole_batch():
    conn = Conn()
    member_seen.posted(conn, [("U2", EARLY), ("U1", LATE), ("U2", LATE)])

    assert conn.ran == [(member_seen.POSTED_SQL, (["U1", "U2"], [LATE, LATE]))]


def test_the_times_only_move_forward():
    for sql, column in ((member_seen.POSTED_SQL, "last_post_at"),
                        (member_seen.LOGGED_IN_SQL, "last_login_at")):
        assert f"held.{column} >= fresh.at" in sql, "a member already this fresh is not touched"
        assert f"seen.{column} < EXCLUDED.{column}" in sql


def test_only_what_members_said_counts_as_them_posting():
    def row(**message):
        return archive.message_row("C1", message["ts"], 1, message, {})

    said = row(ts="1700000000.000100", user="U1", text="hi")
    joined = row(ts="1700000000.000200", user="U2", subtype="channel_join")
    bot = row(ts="1700000000.000300", bot_id="B1")
    nobody = row(ts="1700000000.000400")

    assert archive.member_posts([said, joined, bot, nobody]) == [("U1", said[3])]


def test_a_page_of_history_moves_each_poster_forward_once():
    conn = Conn()
    archive.from_api_many(conn, "C1", [
        {"ts": "1700000000.000100", "user": "U1", "text": "hi"},
        {"ts": "1700000100.000100", "user": "U1", "text": "again"},
        {"ts": "1700000200.000100", "user": "U2", "subtype": "channel_join"},
    ], "conversations.history", "history")

    assert conn.seen() == [(["U1"], [archive.stamp("1700000100.000100")])]


def test_an_access_log_row_is_a_login():
    conn = Conn()
    access_logs_pull.insert_rows(conn, [
        {"user_id": "U1", "date_first": 1790000000, "date_last": 1790003600},
        {"user_id": "U1", "date_first": 1790000000, "date_last": 1790001800, "ip": "10.0.0.1"},
    ], Counts())

    assert conn.seen() == [(["U1"], [datetime.fromtimestamp(1790003600, tz=UTC)])]
