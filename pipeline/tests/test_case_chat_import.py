import threading

from jobs import case_chat_import


def test_event_of_member_message():
    event = case_chat_import.event_of("C0FIRE", {"ts": "1.2", "thread_ts": "1.0", "user": "UONE",
                                                 "text": "hi", "blocks": [{"type": "rich_text"}]})
    assert event == {"channel": "C0FIRE", "ts": "1.2", "thread_ts": "1.0", "user": "UONE",
                     "text": "hi", "blocks": [{"type": "rich_text"}], "files": []}


def test_event_of_file_only_message_keeps_files():
    files = [{"id": "F1", "mimetype": "image/png", "url_private": "https://files.slack.com/a.png"}]
    event = case_chat_import.event_of("C0FIRE", {"ts": "1.4", "thread_ts": "1.0", "user": "U07K4TS9HQE",
                                                 "bot_id": "B07KBDVFXJP", "text": "", "files": files})
    assert event["files"] == files
    assert event["text"] == ""


def test_event_of_bot_message_without_user_uses_bot_id():
    event = case_chat_import.event_of("C0FIRE", {"ts": "1.3", "bot_id": "B0SHROUD", "text": "Case #4"})
    assert event["user"] == "B0SHROUD"
    assert event["blocks"] is None


def test_serve_waits_until_the_link_is_on_and_imported(monkeypatch):
    stopping = threading.Event()
    monkeypatch.setattr(case_chat_import, "ready", lambda: False)
    monkeypatch.setattr(case_chat_import, "run", lambda client: (_ for _ in ()).throw(AssertionError("ran")))
    monkeypatch.setattr(stopping, "wait", lambda seconds: stopping.set())
    case_chat_import.serve(None, stopping)


def test_import_case_skips_lyla_roots_and_nemos_posts(monkeypatch):
    import contextlib

    from jobs import imported_chat
    from jobs.shroud_identity import SHROUD_BOT_USER_ID
    from lyla.mapping import LYLA_BOT_USER_ID

    thread = "1792777065.572749"

    class Conn:
        def execute(self, sql, args=None):
            self.last = sql
            return self

        def fetchall(self):
            return [("C0FIRE", thread)] if "UNION" in self.last else []

    @contextlib.contextmanager
    def session():
        yield Conn()

    stored = []
    monkeypatch.setattr(case_chat_import, "session", session)
    monkeypatch.setattr(case_chat_import, "own_ids", lambda client: {"UNEMO"})
    monkeypatch.setattr(case_chat_import, "replies", lambda client, channel, ts: [
        {"ts": thread, "user": SHROUD_BOT_USER_ID, "text": "report"},
        {"ts": "1792777066.1", "user": LYLA_BOT_USER_ID, "text": "Case #5053"},
        {"ts": "1792777070.1", "user": SHROUD_BOT_USER_ID, "text": "more detail"},
        {"ts": "1792777080.1", "user": "UFIREFIGHTER", "text": "on it"},
        {"ts": "1792777090.1", "user": "UNEMO", "text": "mirror"},
    ])
    monkeypatch.setattr(imported_chat, "report_for_thread", lambda conn, channel, ts: 7)
    monkeypatch.setattr(imported_chat, "known_mirrors", lambda conn, timestamps: set())
    monkeypatch.setattr(case_chat_import.chat, "insert",
                        lambda conn, case_id, event: stored.append(event["ts"]) or (1, True))

    assert case_chat_import.import_case(object(), 5055) == 2
    assert stored == ["1792777070.1", "1792777080.1"]
