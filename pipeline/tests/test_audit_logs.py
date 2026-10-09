import datetime as dt
import pathlib

import pytest

from ingest import audit_logs_pull as pull
from lib import audit_actions, user_agents, useragent
from lib.proxy_client import ProxyError, stamped

WHO = "U1"
APP = "A0BJDDB42N7"
OTHER_ID = "0dc5d1ec-1111-2222-3333-444455556667"


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
    row = pull.monthly_row(entry(), "audit_logs_tail", frozenset(), {}, None)

    assert str(row[0]) == entry()["id"]
    assert row[1] == dt.datetime.fromtimestamp(1790680410, tz=dt.UTC)
    assert row[2] == "user_login"
    assert row[4:6] == ("user", WHO)
    assert row[7:9] == ("user", WHO)


def test_an_entry_with_no_id_or_no_date_is_refused_rather_than_landed():
    assert pull.landable(entry())
    assert not pull.landable(entry(id=""))
    assert not pull.landable(entry(id="not-a-uuid"))
    assert not pull.landable(entry(date_create=None))
    assert not pull.landable(entry(action=""))


def test_our_own_reads_are_marked_so_they_can_be_told_apart():
    entry_row = entry(action="public_channel_preview",
                 context={"app": {"id": APP, "name": "Nemo"}})

    assert pull.view_row(entry_row, 1, {}, frozenset({APP}))[8] is True
    assert pull.view_row(entry_row, 1, {}, frozenset())[8] is False
    assert pull.monthly_row(entry_row, "k", frozenset({APP}), {}, None)[12] is True
    assert pull.monthly_row(entry(), "k", frozenset({APP}), {}, None)[12] is False


def test_a_login_carries_the_address_the_agent_and_the_session():
    row = pull.login_row(entry())

    assert row[0] == WHO
    assert row[2] == "user_login"
    assert row[3] == "157.51.215.171"
    assert row[4] == entry()["context"]["ua"]
    assert row[5] == 12177102026566
    assert str(row[6]) == entry()["id"]


def test_every_own_session_action_with_an_address_makes_a_login_row():
    assert pull.login_row(entry(action="user_login_failed")) is not None
    assert pull.login_row(entry(action="anomaly")) is not None
    assert pull.login_row(entry(action="file_downloaded"))[2] == "file_downloaded"
    assert pull.login_row(entry(action="user_channel_join", details={"type": "JOINED"})) is not None


def test_actions_from_someone_else_s_session_make_no_login_row():
    chrome = entry()["context"]["ua"]
    app = {"ip_address": "1.2.3.4", "ua": chrome, "app": {"id": APP}}
    script = {"ip_address": "1.2.3.4", "ua": "Slack Ruby Client/2.1.0"}
    no_address = {"ua": chrome}

    assert pull.login_row(entry(action="file_downloaded", context=app)) is None
    assert pull.login_row(entry(action="file_downloaded", context=script)) is None
    assert pull.login_row(entry(action="file_downloaded", context=no_address)) is None
    for kind in ("INVITED", "KICKED"):
        assert pull.login_row(entry(action="user_channel_join", details={"type": kind})) is None
    assert pull.login_row(entry(action="file_downloaded",
                                actor={"type": "app", "app": {"id": APP}})) is None


def test_a_sign_in_keeps_its_row_whatever_client_made_it():
    script = {"ip_address": "1.2.3.4", "ua": "Slack Ruby Client/2.1.0"}
    assert pull.login_row(entry(context=script)) is not None


def test_script_clients_are_told_apart_from_people():
    for ua in ("Slack Ruby Client/2.1.0", "ApiApp/1.0", "Python/3.12 aiohttp/3.9.5",
               "Bun/1.1.38", "python-requests/2.31.0", "slack_bolt/1.18"):
        assert useragent.api_client(ua), ua
    for ua in (entry()["context"]["ua"], "Slack_SSB/4.41.105",
               "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0", None):
        assert not useragent.api_client(ua), ua


def test_a_login_with_nobody_behind_it_is_not_written_down():
    assert pull.login_row(entry(actor={"type": "user", "user": {}})) is None
    assert pull.login_row(entry(actor={})) is None


def test_a_session_that_is_not_a_number_does_not_stop_the_row():
    row = pull.login_row(entry(context={"session_id": "nonsense", "ip_address": "1.2.3.4"}))
    assert row[5] is None
    assert row[3] == "1.2.3.4"


def test_the_prefix_is_the_database_s_job_so_two_hosts_on_one_range_group():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0144_login_prefix_is_the_network.sql").read_text()
    assert "GENERATED ALWAYS AS" in sql
    assert "network(set_masklen(ip" in sql
    assert "ip_prefix" not in pull.LOGIN_SQL, "the prefix must not be written by hand"


def test_tail_actions_default_to_all_and_accept_set_names(monkeypatch):
    monkeypatch.delenv("AUDIT_TAIL_ACTIONS", raising=False)
    assert pull.tail_actions() is None

    monkeypatch.setenv("AUDIT_TAIL_ACTIONS", "login")
    assert pull.tail_actions() == pull.LOGIN_ACTIONS

    monkeypatch.setenv("AUDIT_TAIL_ACTIONS", "login_and_channel")
    assert pull.tail_actions() == pull.LOGIN_AND_CHANNEL_ACTIONS

    monkeypatch.setenv("AUDIT_TAIL_ACTIONS", "Identity")
    assert pull.tail_actions() == pull.IDENTITY_ACTIONS

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


def test_each_action_set_has_its_own_coverage_key():
    assert pull.source_key_for(pull.LOGIN_AND_CHANNEL_ACTIONS) == f"{pull.BACKFILL}:login_and_channel"
    assert pull.source_key_for(pull.LOGIN_ACTIONS) == f"{pull.BACKFILL}:login"
    assert pull.source_key_for(pull.CHANNEL_MEMBERSHIP_ACTIONS) == f"{pull.BACKFILL}:channel_membership"
    assert pull.source_key_for(pull.IDENTITY_ACTIONS) == f"{pull.BACKFILL}:identity"
    assert pull.source_key_for(("user_login",)) == f"{pull.BACKFILL}:custom"
    assert pull.source_key_for(None) == f"{pull.BACKFILL}:all"

    keys = {pull.source_key_for(actions) for actions in pull.ACTION_SETS.values()}
    assert len(keys) == len(pull.ACTION_SETS)


def test_every_action_set_fits_one_request():
    for actions in pull.ACTION_SETS.values():
        assert len(actions) <= pull.MOST_ACTIONS
        assert len(set(actions)) == len(actions)


def test_backfill_defaults_to_login_and_channel_actions():
    import inspect

    actions = inspect.signature(pull.backfill).parameters["actions"].default
    assert actions == pull.LOGIN_AND_CHANNEL_ACTIONS
    assert set(pull.CHANNEL_MEMBERSHIP_ACTIONS) <= set(actions)


def test_identity_actions_extend_login_actions_with_account_changes():
    assert pull.IDENTITY_ACTIONS[:len(pull.LOGIN_ACTIONS)] == pull.LOGIN_ACTIONS
    assert {"user_deactivated", "user_reactivated", "user_profile_updated"} <= set(pull.IDENTITY_ACTIONS)


def test_backfill_set_names_default_to_login_and_channel(monkeypatch):
    monkeypatch.delenv("AUDIT_BACKFILL_SETS", raising=False)

    assert pull.backfill_set_names() == ("login_and_channel",)
    assert pull.backfill_sets() == (pull.LOGIN_AND_CHANNEL_ACTIONS,)


def test_backfill_set_names_keep_order_and_drop_duplicates(monkeypatch):
    monkeypatch.setenv("AUDIT_BACKFILL_SETS", " Identity , login_and_channel, identity ")

    assert pull.backfill_set_names() == ("identity", "login_and_channel")
    assert pull.backfill_sets() == (pull.IDENTITY_ACTIONS, pull.LOGIN_AND_CHANNEL_ACTIONS)


def test_unknown_backfill_set_names_are_reported_and_skipped(monkeypatch):
    monkeypatch.setenv("AUDIT_BACKFILL_SETS", "identity,missing_set")

    assert pull.unknown_backfill_sets() == ("missing_set",)
    assert pull.backfill_sets() == (pull.IDENTITY_ACTIONS,)


def test_backfill_next_runs_the_first_set_with_a_pending_day(monkeypatch):
    monkeypatch.setenv("AUDIT_BACKFILL_SETS", "identity,login_and_channel")
    pending = {pull.source_key_for(pull.LOGIN_AND_CHANNEL_ACTIONS)}
    monkeypatch.setattr(pull, "next_slice",
                        lambda conn, source_key, days: dt.date(2026, 1, 15) if source_key in pending else None)
    calls = []

    def fake_backfill(conn, client=None, actions=None):
        calls.append(actions)
        return 7

    monkeypatch.setattr(pull, "backfill", fake_backfill)

    assert pull.backfill_next(object()) == 7
    assert calls == [pull.LOGIN_AND_CHANNEL_ACTIONS]


def test_backfill_next_returns_zero_when_every_set_is_covered(monkeypatch):
    monkeypatch.setenv("AUDIT_BACKFILL_SETS", "identity,login_and_channel")
    monkeypatch.setattr(pull, "next_slice", lambda conn, source_key, days: None)
    calls = []
    monkeypatch.setattr(pull, "backfill", lambda *args, **kwargs: calls.append(args))

    assert pull.backfill_next(object()) == 0
    assert calls == []


def test_an_agent_is_read_once_even_when_it_names_no_system():
    from ingest import useragent_reparse

    assert "FROM slack.user_agent" in useragent_reparse.UNREAD
    assert "read_at IS NULL" in useragent_reparse.UNREAD
    assert "app IS NULL" not in useragent_reparse.UNREAD, (
        "a runtime names no system, so a null os is a finished read, not a pending one; "
        "matching on it re-reads the newest rows forever and never reaches the backlog")
    assert "read_at = now()" in useragent_reparse.REREAD
    assert "coalesce(%s, app)" in useragent_reparse.REREAD, "a read must not clear what it has"


def test_a_landed_agent_counts_as_already_read():
    assert "read_at" in user_agents.UPSERT_SQL and "now()" in user_agents.UPSERT_SQL, \
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

    def executemany(self, sql, rows, returning=False):
        self.ran.append((sql, rows))
        self.returned = [row[0] for row in rows if returning and row[0] not in self.held_ids]

    held_ids = frozenset()
    returned = ()

    def results(self):
        for one in self.returned:
            self.answer = [(one,)]
            yield self
        self.answer = []

    def commit(self):
        pass

    def fetchone(self):
        return (0,)

    answer = ()

    def fetchall(self):
        return list(self.answer)

    def did(self, mark):
        return [args for sql, args in self.ran if mark in sql]


def test_landing_writes_the_event_and_the_login_from_one_pass():
    conn, counts = Conn(), Counts()
    later = entry(id=OTHER_ID, action="user_logout", date_create=entry()["date_create"] + 60)
    landed, seated = pull.insert_rows(conn, [entry(), later], "audit_logs_tail", frozenset(), counts)

    assert (landed, seated) == (2, 2)
    assert counts.rows_in == 2
    assert len(conn.did("INSERT INTO slack.audit_event")[0]) == 2
    [hour] = conn.did("INSERT INTO fd.login_event")[0]
    assert hour[6:] == (2, 1, 0, 0, 2)
    assert conn.did("INSERT INTO fd.login_session")[0] == [(SESSION, WHO, pull.stamp(entry()["date_create"]))]


def test_an_event_already_held_adds_no_sighting():
    conn, counts = Conn(), Counts()
    conn.held_ids = frozenset({pull.event_uuid(entry()["id"])})

    pull.insert_rows(conn, [entry()], "audit_logs_tail", frozenset(), counts)

    assert conn.did("INSERT INTO fd.login_event") == []


def test_sightings_are_counted_per_member_address_agent_and_hour():
    at = dt.datetime(2026, 9, 1, 12, 10, tzinfo=dt.UTC)
    ua = entry()["context"]["ua"]
    agents = {user_agents.digest(ua): 7}

    def row(minute, action="file_downloaded", ip="1.2.3.4", hour=12):
        when = at.replace(hour=hour, minute=minute)
        return (WHO, when, action, ip, ua, None, None)

    rows = pull.hourly([row(10, "user_login"), row(10), row(40, "user_login_failed"), row(50, "anomaly"),
                        row(20, ip="5.6.7.8"), row(5, hour=13)], agents)

    assert rows == [
        (WHO, at.replace(minute=0), "1.2.3.4", 7, at.replace(minute=10), at.replace(minute=50), 3, 0, 1, 1, 3),
        (WHO, at.replace(minute=0), "5.6.7.8", 7, at.replace(minute=20), at.replace(minute=20), 1, 0, 0, 0, 1),
        (WHO, at.replace(hour=13, minute=0), "1.2.3.4", 7, at.replace(hour=13, minute=5),
         at.replace(hour=13, minute=5), 1, 0, 0, 0, 1),
    ]


def test_a_sign_in_names_the_owner_of_its_session_once():
    signed_in = pull.login_row(entry())
    again = pull.login_row(entry(date_create=entry()["date_create"] + 5))
    downloaded = pull.login_row(entry(action="file_downloaded"))

    assert pull.session_rows([again, signed_in, downloaded]) == [(SESSION, WHO, signed_in[1])]


def test_only_a_login_that_worked_counts_as_being_seen():
    conn, counts = Conn(), Counts()
    failed = {"type": "user", "user": {"id": "U2", "name": "nope"}}
    pull.insert_rows(conn, [entry(), entry(id=OTHER_ID, action="user_login_failed", actor=failed)],
                     "audit_logs_tail", frozenset(), counts)

    assert [ids for ids, _ in conn.did("INSERT INTO fd.member_seen")] == [[WHO]]


def test_a_landed_event_is_never_written_twice():
    assert "ON CONFLICT (id, at) DO NOTHING\nRETURNING id" in pull.MONTHLY_SQL
    assert "ON CONFLICT (id, at) DO NOTHING\nRETURNING id" in pull.VIEW_SQL
    assert "ON CONFLICT (user_id, source, hour, ip, ua_id) DO UPDATE" in pull.LOGIN_SQL
    assert "hits = held.hits + EXCLUDED.hits" in pull.LOGIN_SQL
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
    pull.insert_rows(conn, [joined(), joined(id=OTHER_ID, action="user_channel_leave"), entry()],
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

    assert "WHERE read_at IS NULL" in useragent_reparse.UNREAD

    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0193_login_event_by_hour.sql").read_text()
    assert "user_agent_unread_idx ON slack.user_agent (id) WHERE read_at IS NULL" in sql, \
        "the sweep must be free once it has drained"


class Owners(Conn):
    def __init__(self, owners=()):
        super().__init__()
        self.owners = list(owners)
        self.answer = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        if sql == pull.OWNERS_SQL:
            self.answer = self.owners
        return self

    def fetchall(self):
        return self.answer


SESSION = 12177102026566


def test_an_action_in_another_member_s_session_is_dropped():
    downloaded = pull.login_row(entry(action="file_downloaded"))

    assert pull.own_sessions(Owners(owners=[(SESSION, "U9")]), [downloaded]) == []
    assert pull.own_sessions(Owners(owners=[(SESSION, WHO)]), [downloaded]) == [downloaded]
    assert pull.own_sessions(Owners(), [downloaded]) == [downloaded]


def test_a_session_signed_into_in_the_same_batch_has_an_owner():
    other = {"type": "user", "user": {"id": "U9", "name": "other"}}
    signed_in = pull.login_row(entry(actor=other))
    downloaded = pull.login_row(entry(action="file_downloaded"))

    assert pull.own_sessions(Owners(), [signed_in, downloaded]) == [signed_in]


def test_an_address_slack_redacted_is_never_written_as_one():
    redacted = {"ip_address": "redacted", "ua": entry()["context"]["ua"]}

    assert pull.login_row(entry(action="file_downloaded", context=redacted)) is None
    signed_in = pull.login_row(entry(context=redacted))
    assert signed_in is not None and signed_in[3] is None


def test_addresses_are_checked_and_written_in_one_form():
    assert pull.address(" 157.51.215.171 ") == "157.51.215.171"
    assert pull.address("2001:DB8::1") == "2001:db8::1"
    assert pull.address("redacted") is None
    assert pull.address("") is None
    assert pull.address(None) is None


EVENT_ID = "0dc5d1ec-1111-2222-3333-444455556666"


class Shape(Conn):
    def __init__(self, codes=(), agents=()):
        super().__init__()
        self.codes = list(codes)
        self.agents = list(agents)
        self.answer = []

    def execute(self, sql, args=None):
        self.ran.append((sql, args))
        self.answer = {pull.VIEW_CODES_SQL: self.codes, user_agents.IDS_SQL: self.agents}.get(sql, [])
        return self

    def fetchall(self):
        return self.answer


def test_a_full_event_gets_typed_columns_and_its_category():
    actor = {"type": "user", "user": {"id": WHO, "name": "zev", "email": "Zev@Example.COM"}}
    entity = {"type": "channel", "channel": {"id": "C0APH2MMHH7", "name": "lounge"}}
    agent = entry()["context"]["ua"]
    row = pull.monthly_row(entry(action="user_channel_join", actor=actor, entity=entity), "audit_logs_tail",
                           frozenset(), {user_agents.digest(agent): 7}, None)

    assert str(row[0]) == EVENT_ID
    assert row[2:4] == ("user_channel_join", "channels")
    assert row[6] == "zev@example.com"
    assert row[10] == "C0APH2MMHH7"
    assert row[13] == "157.51.215.171"
    assert row[14] == 7
    assert row[15] == 12177102026566


def test_an_event_slack_did_not_give_a_uuid_stays_out_of_the_new_tables():
    assert pull.monthly_row(entry(id="not-a-uuid"), "k", frozenset(), {}, None) is None
    assert pull.view_row(entry(id="not-a-uuid"), 3, {}, frozenset()) is None


def test_a_redacted_address_is_stored_as_no_address():
    row = pull.monthly_row(entry(context={"ip_address": "redacted"}), "k", frozenset(), {}, None)
    assert row[13] is None


def test_the_channel_comes_from_the_entity_whatever_its_kind():
    assert pull.channel_of(entry(entity={"type": "channel", "channel": {"id": "C1"}})) == "C1"
    assert pull.channel_of(entry(entity={"type": "message", "message": {"channel": "C2"}})) == "C2"
    assert pull.channel_of(entry(entity={"type": "huddle", "huddle": {"channel_id": "C3"}})) == "C3"
    assert pull.channel_of(entry(entity={"type": "user", "user": {"id": "U1"}})) is None


def test_high_volume_actions_go_to_the_slim_table_and_the_rest_to_the_monthly_one():
    agent = entry()["context"]["ua"]
    conn = Shape(codes=[("file_downloaded", 3)], agents=[(user_agents.digest(agent), 7)])
    downloaded = entry(id="0dc5d1ec-1111-2222-3333-444455556667", action="file_downloaded",
                       entity={"type": "file", "file": {"id": "F123"}})

    fresh, agents = pull.write_new_shape(conn, [entry(), downloaded], "audit_logs_tail", frozenset())

    assert fresh == {pull.event_uuid(entry()["id"]), pull.event_uuid(downloaded["id"])}
    assert agents == {user_agents.digest(agent): 7}

    [view] = conn.did("INSERT INTO slack.audit_view")
    assert view[0][2:5] == (3, WHO, "F123")
    assert view[0][6] == 7
    [monthly] = conn.did("INSERT INTO slack.audit_event")
    assert monthly[0][2] == "user_login"
    [ensure] = conn.did("slack.ensure_months")
    assert ensure["first"].day == 1 and ensure["ahead"] == pull.MONTHS_AHEAD


def test_an_entry_without_a_uuid_is_dead_lettered_not_landed():
    conn, counts = Conn(), Counts()

    landed, _ = pull.insert_rows(conn, [entry(), entry(id="b")], "audit_logs_tail", frozenset(), counts)

    assert landed == 1
    assert counts.rows_rejected == 1
    assert len(conn.did("INSERT INTO slack.audit_event")[0]) == 1


def test_the_move_to_hours_keeps_every_count_the_finder_reads():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
           / "0193_login_event_by_hour.sql").read_text()
    assert "date_trunc('hour', e.at, 'UTC')" in sql
    assert "min(e.at), max(e.at), count(*)," in sql
    assert "(user_id, source, hour, ip, ua_id) NULLS NOT DISTINCT" in sql
    assert "WHERE session_id IS NOT NULL AND action = 'user_login'" in sql


def test_months_are_created_by_their_owner_and_only_for_the_audit_tables():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
           / "0191_audit_months_run_as_owner.sql").read_text()
    assert "SECURITY DEFINER" in sql and "SET search_path = slack, pg_temp" in sql
    assert "parent NOT IN ('slack.audit_event_monthly'::regclass, 'slack.audit_view'::regclass)" in sql
    assert "FROM PUBLIC" in sql


def test_the_move_copies_every_held_event_then_takes_the_old_name():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
           / "0192_move_audit_events.sql").read_text()
    copy, rest = sql.split("DROP TABLE slack.audit_event;")
    assert "INSERT INTO slack.audit_event_monthly" in copy and "INSERT INTO slack.audit_view" in copy
    assert "ALTER TABLE slack.audit_event_monthly RENAME TO audit_event;" in rest
    assert "parent NOT IN ('slack.audit_event'::regclass, 'slack.audit_view'::regclass)" in rest
    assert "SECURITY DEFINER" in rest


def test_the_move_carries_the_category_of_every_catalogued_action():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
           / "0192_move_audit_events.sql").read_text()
    for action, held in audit_actions.catalogue()["actions"].items():
        assert f"('{action}', '{held['category']}')" in sql
