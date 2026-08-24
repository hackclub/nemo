from bot.engine import evidence


class Answer:
    def __init__(self, rows):
        self.rows = rows

    def fetchone(self):
        return self.rows[0] if self.rows else None

    def fetchall(self):
        return self.rows


class Conn:
    def __init__(self, shares=(), has_primary=False):
        self.shares = list(shares)
        self.has_primary = has_primary
        self.attached = []
        self.kept = []
        self.audited = []

    def execute(self, sql, params=None):
        if sql is evidence.FORWARDS:
            return Answer(self.shares)

        if sql is evidence.ATTACH:
            key = (params["case_id"], params["channel_id"], params["thread_ts"])
            if key in [row[:3] for row in self.attached]:
                return Answer([])
            primary = not self.has_primary
            self.has_primary = True
            thread_id = 100 + len(self.attached)
            self.attached.append((*key, params["added_by"], primary, thread_id))
            return Answer([(thread_id, primary)])

        if sql is evidence.KEEP:
            key = (params["channel_id"], params["thread_ts"], params["message_ts"])
            if key in [(row["channel_id"], row["thread_ts"], row["message_ts"])
                       for row in self.kept]:
                return Answer([])
            self.kept.append(params)
            return Answer([(200 + len(self.kept),)])

        if "fd.audit" in sql:
            self.audited.append(params)
            return Answer([])

        raise AssertionError(f"unexpected query: {sql}")


def share(channel="C0YARROW", thread_ts="1700.100", source_ts="1700.100",
          author="UMILO", body="go back to your own server", permalink="https://x/p/1"):
    return (channel, thread_ts, source_ts, author, body, permalink)


def test_a_standalone_message_is_a_thread_rooted_at_itself():
    conn = Conn([share(thread_ts="1700.500", source_ts="1700.500")])

    evidence.promote(conn, 3949, 7, "UNEMO")

    case_id, channel_id, thread_ts, added_by, primary, _ = conn.attached[0]
    assert (case_id, channel_id, thread_ts) == (3949, "C0YARROW", "1700.500")
    assert primary is True

    kept = conn.kept[0]
    assert kept["is_root"] is True
    assert kept["parent_ts"] is None
    assert kept["message_ts"] == "1700.500"


def test_a_forwarded_reply_hangs_off_the_thread_it_lives_in():
    conn = Conn([share(thread_ts="1700.100", source_ts="1700.900")])

    evidence.promote(conn, 3949, 7, "UNEMO")

    assert conn.attached[0][2] == "1700.100", "the parent, not the reply"
    kept = conn.kept[0]
    assert kept["is_root"] is False
    assert kept["parent_ts"] == "1700.100"
    assert kept["message_ts"] == "1700.900"


def test_two_forwards_from_one_thread_are_one_thread_and_two_messages():
    conn = Conn([share(source_ts="1700.100"), share(source_ts="1700.900")])

    brought = evidence.promote(conn, 3949, 7, "UNEMO")

    assert brought == {"threads": 1, "messages": 2}
    assert len(conn.attached) == 1
    assert [row["message_ts"] for row in conn.kept] == ["1700.100", "1700.900"]


def test_the_same_message_forwarded_twice_is_kept_once():
    conn = Conn([share(), share()])

    assert evidence.promote(conn, 3949, 7, "UNEMO") == {"threads": 1, "messages": 1}


def test_forwards_from_two_channels_are_two_threads():
    conn = Conn([share(channel="C0YARROW"), share(channel="C0LOUNGE")])

    evidence.promote(conn, 3949, 7, "UNEMO")

    assert [row[1] for row in conn.attached] == ["C0YARROW", "C0LOUNGE"]


def test_only_the_first_thread_on_a_case_is_the_primary_one():
    conn = Conn([share(channel="C0YARROW"), share(channel="C0LOUNGE")])

    evidence.promote(conn, 3949, 7, "UNEMO")

    assert [row[4] for row in conn.attached] == [True, False]


def test_a_case_that_already_has_a_primary_keeps_it():
    conn = Conn([share()], has_primary=True)

    evidence.promote(conn, 3949, 7, "UNEMO")

    assert conn.attached[0][4] is False


def test_the_words_and_the_author_come_across():
    conn = Conn([share()])

    evidence.promote(conn, 3949, 7, "UNEMO")

    kept = conn.kept[0]
    assert kept["author"] == "UMILO"
    assert kept["body"] == "go back to your own server"
    assert kept["permalink"] == "https://x/p/1"


def test_a_forward_with_no_author_attaches_the_thread_but_keeps_no_message():
    conn = Conn([share(author=None)])

    brought = evidence.promote(conn, 3949, 7, "UNEMO")

    assert brought == {"threads": 1, "messages": 0}
    assert conn.kept == [], "a row with no author would fail the check constraint"


def test_a_message_with_no_words_is_still_kept():
    conn = Conn([share(body=None)])

    assert evidence.promote(conn, 3949, 7, "UNEMO")["messages"] == 1
    assert conn.kept[0]["body"] is None


def test_a_report_with_no_forwards_brings_nothing():
    conn = Conn([])

    assert evidence.promote(conn, 3949, 7, "UNEMO") == {"threads": 0, "messages": 0}
    assert conn.attached == []
    assert conn.kept == []


def test_the_bot_is_recorded_as_attaching_it_never_the_reporter():
    conn = Conn([share()])

    evidence.promote(conn, 3949, 7, "UNEMO")

    assert conn.attached[0][3] == "UNEMO"


def test_every_attach_leaves_a_trail_saying_it_came_with_the_report():
    conn = Conn([share()])

    evidence.promote(conn, 3949, 7, "UNEMO")

    said = conn.audited[0]
    assert said[0] == "UNEMO"
    assert said[2] == "thread"
    assert said[4] == "attached"


def test_only_forwards_are_asked_for():
    assert "kind = 'forward'" in evidence.FORWARDS
    assert "direction = 'inbound'" in evidence.FORWARDS
    assert "coalesce(s.source_thread_ts, s.source_ts)" in evidence.FORWARDS


def test_neither_write_can_collide_with_a_later_pull():
    assert "ON CONFLICT (case_id, channel_id, thread_ts) DO NOTHING" in evidence.ATTACH
    assert "ON CONFLICT (channel_id, thread_ts, message_ts) DO NOTHING" in evidence.KEEP
    assert "'shroud'" in evidence.KEEP, "so a pulled message is tellable from a forwarded one"
