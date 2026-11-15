import datetime as dt

from bot.nemo import case_modal, profile

AT = dt.datetime(2026, 10, 17, 12, 0, tzinfo=dt.UTC)

REPORT_CASE = "JOIN fd.case_reports r ON r.case_id = c.id"
QUEUE_CASE = "SELECT id, category_key"
OPENING_SQL = "mirrored_as = 'card'"
ACTION_COUNT = "SELECT count(*) FROM fd.actions"
ENTRIES_SQL = "type_key, target_user_id, expires_at, reason"
NOTES_SQL = "FROM fd.notes"
THREADS_SQL = "FROM fd.case_threads"


class Conn:
    def __init__(self, rows=None, lists=None):
        self.rows = rows or {}
        self.lists = lists or {}
        self.last_sql = ""

    def execute(self, sql, args=None):
        self.last_sql = sql
        return self

    def fetchone(self):
        for marker, row in self.rows.items():
            if marker in self.last_sql:
                return row
        return None

    def fetchall(self):
        for marker, rows in self.lists.items():
            if marker in self.last_sql:
                return rows
        return []


class Client:
    pass


def queue_case_row(case_id, opened_by="UOPENER"):
    return (case_id, None, None, "C_FIRE", "5.5", None, opened_by, None, None, None, None)


def report_case_row(case_id, body, anonymous=True, reporter=None):
    return (case_id, None, None, 3, anonymous, reporter, body, "1.1", None, None, None, None, "C_FIRE",
            None, None, "dm", False)


def card_of(view):
    return next(one for one in view["blocks"] if one["type"] == "card")


def test_build_queue_case_quotes_opening_text():
    conn = Conn({QUEUE_CASE: queue_case_row(12), OPENING_SQL: (7, "spam in the lounge")})

    view = case_modal.build(None, conn, 12)

    assert card_of(view)["body"]["text"] == "> spam in the lounge"


def test_build_queue_case_without_opening_has_no_body():
    view = case_modal.build(None, Conn({QUEUE_CASE: queue_case_row(12)}), 12)

    assert "body" not in card_of(view)


def test_build_report_case_quotes_report_body():
    conn = Conn({REPORT_CASE: report_case_row(12, "they spammed"), ACTION_COUNT: (0,)})

    view = case_modal.build(None, conn, 12)

    assert card_of(view)["body"]["text"] == "> they spammed"


def test_build_unknown_case_returns_none():
    assert case_modal.build(None, Conn({}), 99) is None


def test_build_anonymous_report_hides_reporter_and_skips_profile_lookup(monkeypatch):
    looked_up = []
    monkeypatch.setattr(profile, "profile", lambda client, user_id: looked_up.append(user_id))
    conn = Conn({REPORT_CASE: report_case_row(12, "text", anonymous=True, reporter="UREPORTER"),
                 ACTION_COUNT: (0,)})

    card = card_of(case_modal.build(Client(), conn, 12))

    assert card["title"]["text"] == "Anonymous" and "icon" not in card and looked_up == []


def test_build_named_report_uses_reporter_name_and_icon(monkeypatch):
    monkeypatch.setattr(profile, "profile", lambda client, user_id: {"name": "r", "icon": "https://img/r.png"})
    conn = Conn({REPORT_CASE: report_case_row(12, "text", anonymous=False, reporter="UREPORTER"),
                 ACTION_COUNT: (0,)})

    card = card_of(case_modal.build(Client(), conn, 12))

    assert card["title"]["text"] == "<@UREPORTER>"
    assert card["icon"]["image_url"] == "https://img/r.png"


def test_build_queue_case_titles_with_opener(monkeypatch):
    monkeypatch.setattr(profile, "profile", lambda client, user_id: {"name": "o", "icon": None})

    card = card_of(case_modal.build(Client(), Conn({QUEUE_CASE: queue_case_row(12)}), 12))

    assert card["title"]["text"] == "<@UOPENER>" and "icon" not in card


def test_build_without_client_skips_profile_lookup():
    card = card_of(case_modal.build(None, Conn({QUEUE_CASE: queue_case_row(12)}), 12))

    assert card["title"]["text"] == "<@UOPENER>" and "icon" not in card


def test_build_report_case_links_report_thread():
    conn = Conn({REPORT_CASE: report_case_row(12, "text"), ACTION_COUNT: (0,)})

    footer = case_modal.build(None, conn, 12)["blocks"][-1]["elements"][0]["text"]

    assert "p11|Open thread>" in footer


def test_build_queue_case_links_card_thread():
    footer = case_modal.build(None, Conn({QUEUE_CASE: queue_case_row(12)}), 12)["blocks"][-1]["elements"][0]["text"]

    assert "p55|Open thread>" in footer


def test_build_lists_live_actions_and_notes():
    conn = Conn(
        {QUEUE_CASE: queue_case_row(12)},
        {
            ENTRIES_SQL: [("shush", "USUBJECT", None, "spam", "UMOD", AT, {})],
            NOTES_SQL: [("UMOD", "likely an alternate", AT)],
        },
    )

    text = str(case_modal.build(None, conn, 12)["blocks"])

    assert "*Shush*" in text and "spam" in text and "likely an alternate" in text


def test_fetch_entries_reads_channel_from_details():
    conn = Conn(lists={ENTRIES_SQL: [("channel_ban", "USUBJECT", AT, "spam", "UMOD", AT, {"channel_id": "CLOUNGE"})]})

    assert case_modal.fetch_entries(conn, 12)[0]["channel_id"] == "CLOUNGE"


def test_build_passes_notice_to_view():
    view = case_modal.build(None, Conn({QUEUE_CASE: queue_case_row(12)}), 12, "Case 12 is already open")

    assert view["blocks"][0]["elements"][0]["text"] == "Case 12 is already open"



def test_build_lists_slack_threads_of_the_case():
    conn = Conn({QUEUE_CASE: queue_case_row(12)}, {THREADS_SQL: [("C0LOUNGE", "1762790400.123456")]})

    text = str(case_modal.build(None, conn, 12)["blocks"])

    assert "<#C0LOUNGE>  <https://hackclub.slack.com/archives/C0LOUNGE/p1762790400123456|Open thread>" in text
    assert "<!date^1762790400^{ago}" in text
    assert "Added by" not in text


def test_threads_sql_covers_merged_cases_and_skips_removed_threads():
    assert "c.duplicate_of = f.id" in case_modal.CASE_THREADS
    assert "removed_at IS NULL" in case_modal.CASE_THREADS
