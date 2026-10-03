import datetime as dt
import pathlib

import pytest

from ingest import audit_logs_pull as pull
from lib import useragent
from lib.proxy_client import ProxyError, stamped

WHO = "U1"
APP = "A0BJDDB42N7"


def entry(**over):
    row = {
        "id": "0dc5d1ec-1111-2222-3333-444455556666",
        "date_create": 1790680410,
        "action": "user_login",
        "actor": {"type": "user", "user": {"id": WHO, "name": "zev"}},
        "entity": {"type": "user", "user": {"id": WHO}},
        "context": {
            "location": {"type": "workspace", "id": "T0266FRGM", "name": "Hack Club"},
            "ua": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/141.0.0.0 Safari/537.36",
            "ip_address": "157.51.215.171",
            "session_id": 12177102026566,
        },
    }
    row.update(over)
    return row


class Counts:
    def __init__(self):
        self.rows_in = 0
        self.rows_rejected = 0


def test_an_entry_becomes_a_row_the_database_will_take():
    row = pull.event_row(entry(), "audit_logs_tail", frozenset())

    assert row[0] == entry()["id"]
    assert row[1] == dt.datetime.fromtimestamp(1790680410, tz=dt.UTC)
    assert row[2] == "user_login"
    assert row[3:5] == ("user", WHO)
    assert row[5:7] == ("user", WHO)


def test_an_entry_with_no_id_or_no_date_is_refused_rather_than_landed():
    assert pull.event_row(entry(id=""), "k", frozenset()) is None
    assert pull.event_row(entry(date_create=None), "k", frozenset()) is None
    assert pull.event_row(entry(action=""), "k", frozenset()) is None


def test_our_own_reads_are_marked_so_they_can_be_told_apart():
    entry_row = entry(action="public_channel_preview",
                 context={"app": {"id": APP, "name": "Nemo"}})

    assert pull.event_row(entry_row, "k", frozenset({APP}))[8] is True
    assert pull.event_row(entry_row, "k", frozenset())[8] is False
    assert pull.event_row(entry(), "k", frozenset({APP}))[8] is False


def test_a_login_carries_the_address_the_agent_and_the_session():
    row = pull.login_row(entry())

    assert row[0] == WHO
    assert row[2] == "user_login"
    assert row[3] == "157.51.215.171"
    assert row[5] == "Chrome 141.0.0.0"
    assert row[6] == "Windows 10 or 11"
    assert row[7] == 12177102026566


def test_only_the_actions_that_seat_somebody_make_a_login():
    assert pull.login_row(entry(action="user_login_failed")) is not None
    assert pull.login_row(entry(action="anomaly")) is not None
    assert pull.login_row(entry(action="file_downloaded")) is None
    assert pull.login_row(entry(action="user_channel_join")) is None


def test_a_login_with_nobody_behind_it_is_not_written_down():
    assert pull.login_row(entry(actor={"type": "user", "user": {}})) is None
    assert pull.login_row(entry(actor={})) is None


def test_a_session_that_is_not_a_number_does_not_stop_the_row():
    row = pull.login_row(entry(context={"session_id": "nonsense", "ip_address": "1.2.3.4"}))
    assert row[7] is None
    assert row[3] == "1.2.3.4"


def test_the_prefix_is_the_database_s_job_so_two_hosts_on_one_range_group():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0144_login_prefix_is_the_network.sql").read_text()
    assert "GENERATED ALWAYS AS" in sql
    assert "network(set_masklen(ip" in sql
    assert "ip_prefix" not in pull.LOGIN_SQL, "the prefix must not be written by hand"


def test_the_tail_asks_for_everything_unless_it_is_told_to_narrow(monkeypatch):
    monkeypatch.delenv("AUDIT_TAIL_ACTIONS", raising=False)
    assert pull.tail_actions() is None

    monkeypatch.setenv("AUDIT_TAIL_ACTIONS", "logins")
    assert pull.tail_actions() == pull.LOGIN_ACTIONS

    monkeypatch.setenv("AUDIT_TAIL_ACTIONS", " user_login , anomaly ")
    assert pull.tail_actions() == ("user_login", "anomaly")


def test_no_more_actions_are_asked_for_than_slack_will_take(monkeypatch):
    monkeypatch.setenv("AUDIT_TAIL_ACTIONS", ",".join(f"a{n}" for n in range(60)))
    assert len(pull.tail_actions()) == pull.MOST_ACTIONS


class Refusing:

    def __init__(self, bad="message_deleted"):
        self.bad = bad
        self.asked = []

    def call(self, _method, params, **_over):
        self.asked.append(params.get("action"))
        if self.bad in str(params.get("action", "")).split(","):
            raise refusal()
        return {"entries": [], "response_metadata": {"next_cursor": ""}}

    def paginate(self, _method, params, _key, **_over):
        self.asked.append(params.get("action"))
        if self.bad in str(params.get("action", "")).split(","):
            raise refusal()
        return iter(())


def refusal():
    failure = ProxyError("proxy returned 400: audit 400: Bad Request")
    failure.http_status = 400
    return failure


def test_one_action_slack_will_not_take_does_not_stop_the_rest(monkeypatch):
    pull.forget_refusals()
    client = Refusing()
    counts = Counts()

    landed, seated = pull.walk(client, Conn(), "k", counts,
                               actions=("user_login", "message_deleted", "anomaly"))

    assert (landed, seated) == (0, 0)
    assert "message_deleted" in pull.refused_actions()
    assert "user_login" not in pull.refused_actions()
    assert client.asked[-1] == "user_login,anomaly", "it walks again without the refused one"
    pull.forget_refusals()


def test_an_action_once_refused_is_not_asked_for_again(monkeypatch):
    pull.forget_refusals()
    client = Refusing()
    pull.walk(client, Conn(), "k", counts_for(), actions=("user_login", "message_deleted"))

    client.asked.clear()
    pull.walk(client, Conn(), "k", counts_for(), actions=("user_login", "message_deleted"))
    assert all("message_deleted" not in str(one) for one in client.asked)
    pull.forget_refusals()


def test_a_pass_where_every_action_is_refused_lands_nothing_rather_than_everything():
    pull.forget_refusals()
    client = Refusing(bad="user_login")
    assert pull.walk(client, Conn(), "k", counts_for(), actions=("user_login",)) == (0, 0)
    assert pull.walk(client, Conn(), "k", counts_for(), actions=("user_login",)) == (0, 0)
    pull.forget_refusals()


def test_a_refusal_with_no_action_filter_is_not_swallowed():
    pull.forget_refusals()

    class Always:
        def paginate(self, *_args, **_over):
            raise refusal()

    with pytest.raises(ProxyError):
        pull.walk(Always(), Conn(), "k", counts_for())


def counts_for():
    return Counts()


def test_a_slice_covers_one_whole_day_in_utc():
    start, stop = pull.bounds(dt.date(2026, 9, 29))

    assert start == dt.datetime(2026, 9, 29, tzinfo=dt.UTC)
    assert stop == dt.datetime(2026, 9, 30, tzinfo=dt.UTC)
    assert (stop - start) == dt.timedelta(days=1)


def test_the_action_set_is_part_of_the_coverage_key_so_a_window_cannot_lie():
    assert pull.source_key_for(pull.LOGIN_ACTIONS).endswith(":logins")
    assert pull.source_key_for(pull.CHANNEL_ACTIONS).endswith(":channels")
    assert pull.source_key_for(pull.WATCHED_ACTIONS).endswith(":watched")
    assert pull.source_key_for(None).endswith(":all")

    keys = {pull.source_key_for(one) for one in
            (pull.LOGIN_ACTIONS, pull.CHANNEL_ACTIONS, pull.WATCHED_ACTIONS, None)}
    assert len(keys) == 4, "a widened set must not inherit a narrower set's coverage"


def test_the_backfill_walks_the_channel_actions_as_well_as_the_logins():
    import inspect

    actions = inspect.signature(pull.backfill).parameters["actions"].default
    assert actions == pull.WATCHED_ACTIONS
    assert set(pull.CHANNEL_ACTIONS) <= set(actions)
    assert len(actions) <= pull.MOST_ACTIONS, "slack takes only so many actions in one call"


def test_an_agent_is_read_once_even_when_it_names_no_system():
    from ingest import useragent_reparse

    assert "ua_read_at IS NULL" in useragent_reparse.UNREAD
    assert "ua_app IS NULL" not in useragent_reparse.UNREAD, (
        "a runtime names no system, so a null ua_os is a finished read, not a pending one; "
        "matching on it re-reads the newest rows forever and never reaches the backlog")
    assert "ua_read_at = now()" in useragent_reparse.REREAD
    assert "coalesce(%s, ua_app)" in useragent_reparse.REREAD, "a read must not clear what it has"


def test_a_landed_agent_counts_as_already_read():
    from ingest import access_logs_pull

    assert "ua_read_at" in pull.LOGIN_SQL and "now()" in pull.LOGIN_SQL
    assert "ua_read_at" in access_logs_pull.ROW_SQL, \
        "what the puller parses needs no second pass"


def test_the_access_log_walk_stops_at_what_we_already_hold():
    from ingest import access_logs_pull

    src = pathlib.Path(access_logs_pull.__file__).read_text()
    assert "newest_held(conn)" in src
    assert "caught_up = True" in src and "break" in src, \
        "slack hands the access log back newest first, so the walk stops at the watermark"
    assert "walk.close()" in src, "the generator is closed so no further page is asked for"
    assert access_logs_pull.LAP_SECONDS >= 1
    assert access_logs_pull.MOST_PAGES >= 1, "a cold start must still be bounded"


def test_the_tail_laps_back_a_second_so_the_seam_cannot_drop_an_event():
    assert pull.LAP_SECONDS >= 1


def test_the_window_always_bounds_the_walk_even_when_resuming():
    held = []

    class Client:
        def paginate(self, _method, asked, *_args, **kwargs):
            held.append((dict(asked), kwargs.get("start_cursor")))
            return []

    when = dt.datetime(2026, 9, 29, tzinfo=dt.UTC)
    pull.walk(Client(), Conn(), "k", Counts(), oldest=when, start_cursor="abc")

    asked, cursor = held[0]
    assert cursor == "abc"
    assert asked["oldest"] == int(when.timestamp()), \
        "slack pages newest first, so oldest is the stop; without it the walk never ends"


def test_a_resumed_walk_keeps_the_window_the_cursor_was_minted_for(monkeypatch):
    saved = {}
    monkeypatch.setattr(pull, "save_cursor",
                        lambda _conn, _key, value: saved.update(value=value))

    when = dt.datetime(2026, 9, 29, 12, tzinfo=dt.UTC)
    pull.keep_place(Conn(), pull.TAIL, when, "abc")
    assert saved["value"] == f"{int(when.timestamp())}|abc"

    monkeypatch.setattr(pull, "get_cursor", lambda _conn, _key: saved["value"])
    cursor, window = pull.held_place(Conn(), pull.TAIL)
    assert cursor == "abc"
    assert window == when, "an interrupted walk resumes on its own window, not a fresh one"


def test_a_cursor_with_no_window_is_not_resumed(monkeypatch):
    monkeypatch.setattr(pull, "get_cursor", lambda _conn, _key: "bare-cursor-no-mark")
    assert pull.held_place(Conn(), pull.TAIL) == (None, None)

    monkeypatch.setattr(pull, "get_cursor", lambda _conn, _key: "")
    assert pull.held_place(Conn(), pull.TAIL) == (None, None)


def test_a_cursor_slack_will_not_take_is_dropped_so_the_tail_can_recover(monkeypatch):
    import contextlib

    cleared = []
    monkeypatch.setattr(pull, "get_cursor", lambda _conn, _key: "1790575062|stale")
    monkeypatch.setattr(pull, "save_cursor",
                        lambda _conn, key, value: cleared.append((key, value)))
    monkeypatch.setattr(pull, "watermark", lambda _conn: None)

    @contextlib.contextmanager
    def bookkeeping(*_args, **_kwargs):
        yield Counts()

    monkeypatch.setattr(pull, "ingest_run", bookkeeping)

    def refuse(*_args, **_kwargs):
        raise stamped(ProxyError("audit 400: refused"), 400, False)

    monkeypatch.setattr(pull, "walk", refuse)

    with pytest.raises(ProxyError):
        pull.tail(Conn(), client=object())

    assert (pull.TAIL, "") in cleared, "a wedged cursor must not survive the failed run"


def test_a_failure_that_is_not_a_refusal_leaves_the_cursor_where_it_was(monkeypatch):
    import contextlib

    cleared = []
    monkeypatch.setattr(pull, "get_cursor", lambda _conn, _key: "1790575062|good")
    monkeypatch.setattr(pull, "save_cursor",
                        lambda _conn, key, value: cleared.append((key, value)))
    monkeypatch.setattr(pull, "watermark", lambda _conn: None)

    @contextlib.contextmanager
    def bookkeeping(*_args, **_kwargs):
        yield Counts()

    monkeypatch.setattr(pull, "ingest_run", bookkeeping)

    def blew_up(*_args, **_kwargs):
        raise stamped(ProxyError("audit 500: slack fell over"), 500, False)

    monkeypatch.setattr(pull, "walk", blew_up)

    with pytest.raises(ProxyError):
        pull.tail(Conn(), client=object())

    assert cleared == [], "a passing cursor must survive a wobble at slack's end"


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

    def commit(self):
        pass

    def fetchone(self):
        return (0,)

    def fetchall(self):
        return []

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


def test_landing_writes_the_event_and_the_login_from_one_pass():
    conn, counts = Conn(), Counts()
    landed, seated = pull.insert_rows(conn, [entry(), entry(id="b", action="file_downloaded")],
                               "audit_logs_tail", frozenset(), counts)

    assert (landed, seated) == (2, 1)
    assert counts.rows_in == 2
    assert len(conn.did("INSERT INTO slack.audit_event")[0]) == 2
    assert len(conn.did("INSERT INTO fd.login_event")[0]) == 1


def test_a_landed_event_is_never_written_twice():
    assert "ON CONFLICT (id) DO NOTHING" in pull.EVENT_SQL
    assert "ON CONFLICT (user_id, at, source) DO UPDATE" in pull.LOGIN_SQL
    assert "ON CONFLICT (audit_id) DO NOTHING" in pull.CHANNEL_SQL


def test_an_address_slack_carried_fills_an_identity_we_never_had():
    row = pull.identity_row(entry(actor={"type": "user", "user": {
        "id": WHO, "name": "Aleksa Lutovac", "email": "kid@throwaway.example"}}))

    assert row[0] == WHO
    assert row[1] == "Aleksa Lutovac"
    assert row[2] == "kid@throwaway.example"


def test_an_actor_with_no_address_leaves_the_identity_alone():
    assert pull.identity_row(entry()) is None
    assert pull.identity_row(entry(actor={"type": "user", "user": {"id": WHO}})) is None
    assert pull.identity_row(entry(actor={"type": "app", "app": {"id": "A1"}})) is None


def test_an_identity_we_already_hold_is_never_written_over():
    assert "coalesce(fd.member_identity.email, EXCLUDED.email)" in pull.IDENTITY_SQL
    assert "purged_at IS NULL" in pull.IDENTITY_SQL, "a purged identity must stay purged"
    assert "EXISTS (SELECT 1 FROM fd.member" in pull.IDENTITY_SQL


def test_one_write_per_member_a_page_however_often_they_appear():
    conn, counts = Conn(), Counts()
    actor = {"type": "user", "user": {"id": WHO, "name": "Zev", "email": "z@throwaway.example"}}
    pull.insert_rows(conn, [entry(actor=actor), entry(id="b", actor=actor), entry(id="c", actor=actor)],
              "audit_logs_tail", frozenset(), counts)

    assert len(conn.did("INSERT INTO fd.member_identity")[0]) == 1


ROOM = {"type": "channel", "channel": {"id": "C1", "name": "lounge", "privacy": "public"}}


def joined(**over):
    row = {"action": "user_channel_join", "entity": ROOM, "details": {"is_workflow": False}}
    row.update(over)
    return entry(**row)


def test_a_room_somebody_walks_into_is_written_down_with_the_room_it_was():
    row = pull.channel_row(joined())

    assert row[2] == WHO
    assert row[3] == "C1"
    assert row[4] == "lounge"
    assert row[5] == "public"
    assert row[6] == pull.JOINED
    assert row[7] is False


def test_leaving_is_kept_apart_from_arriving():
    assert pull.channel_row(joined(action="user_channel_leave"))[6] == pull.LEFT
    assert pull.channel_row(joined(action="user_login")) is None


def test_a_room_a_workflow_put_them_in_says_so_so_it_is_not_read_as_a_raid():
    assert pull.channel_row(joined(details={"is_workflow": True}))[7] is True


def test_a_join_missing_the_member_or_the_room_is_not_written_down():
    assert pull.channel_row(joined(actor={})) is None
    assert pull.channel_row(joined(entity={"type": "channel", "channel": {}})) is None
    assert pull.channel_row(joined(entity={})) is None
    assert pull.channel_row(joined(date_create=None)) is None


def test_landing_projects_the_rooms_alongside_the_events():
    conn, counts = Conn(), Counts()
    pull.insert_rows(conn, [joined(), joined(id="b", action="user_channel_leave"), entry()],
              "audit_logs_tail", frozenset(), counts)

    rooms = conn.did("INSERT INTO fd.member_channel_join")[0]
    assert len(rooms) == 2
    assert {one[6] for one in rooms} == {pull.JOINED, pull.LEFT}


def test_the_rooms_are_projected_org_wide_not_only_where_nemo_sits():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0148_member_channel_joins.sql").read_text()
    assert "FROM slack.audit_event" in sql, "the history already landed must be projected too"
    assert "member_channel_join_room_idx" in sql, "fan-out is read by room and time"


@pytest.mark.parametrize(("agent", "app", "system"), [
    ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/141.0.0.0 Safari/537.36",
     "Chrome 141.0.0.0", "Windows 10 or 11"),
    ("slack/26.09.41.0.90016209 (samsung SM-A235F; Android 14; store com.android.vending)",
     "Slack Android 26.09.41.0.90016209", "Android 14"),
    ("Python/3.13.15 slackclient/3.43.0 Linux/4.19.0-gvisor", "Slack SDK", "Linux"),
    ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Slack_SSB/4.45.69 Electron/32.2.5",
     "Slack Desktop 4.45.69", "macOS 10.15.7"),
    ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) Version/18.2 Safari/604.1",
     "Safari 18.2", "iOS 18.2"),
    ("com.tinyspeck.chatlyio/26.09.20 (iPhone; iOS 26.6.2; Scale/3.00)",
     "Slack iOS 26.09.20", "iOS 26.6.2"),
    ("com.tinyspeck.chatlyio.NotificationService/26.09.30 (iPhone; iOS 27.0; Scale/3.00)",
     "Slack iOS 26.09.30", "iOS 27.0"),
    ("Mozilla/5.0 (iPhone; CPU iPhone OS 26_4_2 like Mac OS X) AppleWebKit/605.1.15 "
     "(KHTML, like Gecko) CriOS/154.0.8037.55 Mobile/15E148 Safari/604.1",
     "Chrome 154.0.8037.55", "iOS 26.4.2"),
    ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) FxiOS/127.0 Mobile Safari/605.1",
     "Firefox 127.0", "iOS 17.5"),
])
def test_the_agent_string_is_read_into_an_app_and_a_system(agent, app, system):
    seen = useragent.parse(agent)
    assert seen["ua_app"] == app
    assert seen["ua_os"] == system


def test_an_agent_string_nobody_recognises_does_not_blow_up():
    assert useragent.parse("") == {"ua": None, "ua_app": None, "ua_os": None}
    assert useragent.parse("something else entirely")["ua_app"] is None


def test_the_agent_string_is_kept_whole_however_long_it_is():
    agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " + "Padding/1.0 " * 60 + "End/1"
    assert len(agent) > 700
    assert useragent.parse(agent)["ua"] == agent, "the raw agent string is never cut short"


def test_a_version_is_kept_whole_rather_than_cut_to_its_first_number():
    seen = useragent.parse("Mozilla/5.0 (Windows NT 10.0) Chrome/154.0.8037.55 Safari/537.36")
    assert seen["ua_app"] == "Chrome 154.0.8037.55"
    assert not hasattr(useragent, "major"), "nothing should be rounding a version down"
    assert not hasattr(useragent, "short"), "nothing should be cutting a string short"


def test_the_slack_phone_apps_are_told_apart_from_a_browser_on_the_phone():
    phone = useragent.parse("com.tinyspeck.chatlyio/26.09.20 (iPhone; iOS 26.6.2; Scale/3.00)")
    browser = useragent.parse(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_4_2 like Mac OS X) CriOS/154.0.8037.55 Safari/604.1")

    assert phone["ua_app"].startswith("Slack iOS")
    assert browser["ua_app"].startswith("Chrome")
    assert phone["ua_os"] == "iOS 26.6.2"
    assert browser["ua_os"] == "iOS 26.4.2"


def test_an_agent_landed_before_the_reader_knew_it_is_read_again():
    from ingest import useragent_reparse

    assert "ua IS NOT NULL" in useragent_reparse.UNREAD

    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0152_agents_we_have_read.sql").read_text()
    assert "login_event_unread_agent_idx" in sql
    assert "ua_read_at IS NULL" in sql, "the sweep must be free once it has drained"
