import contextlib
import pathlib

from ingest import member_links as links
from ingest import member_links_v2 as v2


def test_every_signal_belongs_to_a_family_with_a_cap():
    caps = v2.families()
    for name, one in v2.signals().items():
        assert one["family"] in caps, name
    for family, one in caps.items():
        assert one["cap"] > 0, family


def test_only_identity_evidence_can_reach_certain_alone():
    certain = links.scoring()["certain"]
    for family, one in v2.families().items():
        if family != "identity":
            assert one["cap"] < certain, family
    assert v2.signals()["mailbox_alias"]["weight"] >= certain


def test_the_family_table_lines_up_signal_by_signal():
    table = v2.family_table(links.catalogue())

    assert len({len(column) for column in table.values()}) == 1
    at = table["signals"].index("session_agent")
    assert table["families"][at] == "device"
    assert table["corroborating"][at] is True


def test_each_family_is_capped_before_the_families_are_added():
    assert "least(sum(b.score), f.cap)" in v2.PASS
    assert "bool_or(NOT corroborating)" in v2.PASS


def test_an_unchanged_link_is_not_written_again():
    assert "IS DISTINCT FROM" in v2.LAND
    assert "NOT EXISTS (SELECT 1 FROM link_pass" in v2.SWEEP
    assert "computed_at" not in v2.SWEEP


def test_links_v2_are_held_one_way_round():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
           / "0184_member_link_v2.sql").read_text()
    assert "CHECK (a_user_id < b_user_id)" in sql
    assert "PRIMARY KEY (a_user_id, b_user_id)" in sql


def test_a_pass_gathers_once_then_lands_sweeps_and_counts(monkeypatch, capsys):
    ran = []

    class Counts:
        rows_in = 0
        rows_rejected = 0

    class Cursor:
        rowcount = 0

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def execute(self, sql, _params=None):
            ran.append(sql)
            self.rowcount = {v2.LAND: 4, v2.SWEEP: 1}.get(sql, 0)

        def fetchone(self):
            return (9,)

    class Conn:
        def cursor(self):
            return Cursor()

        def execute(self, sql, _params=None):
            ran.append(sql)

        def commit(self):
            ran.append("commit")

    @contextlib.contextmanager
    def bookkeeping(*_args, **_kwargs):
        yield Counts()

    monkeypatch.setattr(v2, "ingest_run", bookkeeping)
    monkeypatch.setattr(links, "mark_shared", lambda _conn, _held: 2)
    monkeypatch.setattr(v2, "gather", lambda _conn, _held: {"ip_stable": 3})

    assert v2.run(Conn()) == 4
    ran[:] = [one for one in ran if one not in ("ANALYZE shared_ip", "ANALYZE link_part")]
    assert ran[:13] == [v2.PASS, v2.PASS_INDEX, "ANALYZE link_pass", v2.PRESENCE, v2.PRESENCE_INDEX,
                        "ANALYZE presence", v2.AGAINST, v2.STAFF_TEST, v2.CLASSROOM, v2.HOUSEHOLD,
                        v2.BELOW_FLOOR, v2.LAND, v2.SWEEP]
    assert ran[-1] == "commit"
    assert "9 link(s) kept, 4 written, 1 dropped" in capsys.readouterr().out


def test_the_new_finder_takes_its_network_evidence_from_the_class_aware_signals():
    names = set(v2.signals())

    assert {"ip_stable", "ip_same_hour", "ip_many", "ip_hourly", "ip_prefix_stable"} <= names
    assert not {"ip_exact", "ip_prefix"} & names
    assert {"email_domain", "session_agent", "joined_together"} <= names


def test_a_home_range_only_counts_alongside_another_family():
    assert v2.signals()["ip_prefix_stable"]["corroborating"] is True


def test_each_signal_reads_the_evidence_built_for_it():
    held = v2.signals()

    stable, _ = v2.evidence("ip_stable", held["ip_stable"], 2)
    hourly, _ = v2.evidence("ip_hourly", held["ip_hourly"], 2)
    domain, _ = v2.evidence("email_domain", held["email_domain"], 2)
    together, args = v2.evidence("joined_together", held["joined_together"], 2)

    assert "FROM sighting" in stable and "class = 'stable'" in stable
    assert "HAVING sum(seen) >= 2" in stable
    assert "'rotating', 'vpn', 'hosting', 'tor'" in hourly and "md5(e.ua)" in hourly
    assert "fd.member_identity" in domain
    assert together == links.TOGETHER_SQL and args["window"] == 300
    assert v2.evidence("nothing", {"weight": 1, "crowd_ceiling": 2}, 2) == (None, None)


def test_an_address_another_isp_rotates_through_is_treated_as_rotating():
    assert "WHEN EXISTS (SELECT 1 FROM shared_ip s WHERE s.ip = e.ip) THEN 'rotating'" in v2.SIGHTING


def test_hourly_evidence_keeps_one_row_per_pair():
    assert set(v2.COLLAPSED) == {"ip_same_hour", "ip_hourly"}
    assert "DISTINCT ON (a_user_id, b_user_id)" in v2.COLLAPSED_PART


def test_two_countries_in_one_hour_count_against_a_link_unless_one_is_a_vpn():
    assert v2.against()["two_countries"]["weight"] < 0
    assert "s.class NOT IN ('vpn', 'hosting', 'tor')" in v2.PRESENCE
    assert "coalesce(e.country, n.country) AS country" in v2.SIGHTING
    assert "b.hour = a.hour AND b.country <> a.country" in v2.AGAINST


def test_the_country_check_reads_only_the_members_of_candidate_links():
    assert "FROM sighting s" in v2.PRESENCE
    assert "SELECT a_user_id FROM link_pass UNION SELECT b_user_id FROM link_pass" in v2.PRESENCE
    assert "fd.login_event" not in v2.AGAINST


def test_a_word_for_word_build_is_device_evidence_and_ja4_only_backs_it_up():
    held = v2.signals()

    assert held["device_agent"]["family"] == "device"
    assert not held["device_agent"].get("corroborating")
    assert held["device_ja4"]["corroborating"] is True
    assert held["device_agent"]["crowd_ceiling"] <= 25


def test_device_evidence_reads_the_full_agent_and_the_anomaly_fingerprint():
    held = v2.signals()

    agent, _ = v2.evidence("device_agent", held["device_agent"], 2)
    ja4, _ = v2.evidence("device_ja4", held["device_ja4"], 2)

    assert "ua AS value" in agent and f"length(ua) >= {v2.SHORTEST_AGENT}" in agent
    assert "client_ja4_fingerprint" in ja4 and "action = 'anomaly'" in ja4
    assert "BETWEEN 2 AND %(ceiling)s" in agent


def test_a_shared_build_alone_stays_below_strong():
    held = v2.signals()
    assert held["device_agent"]["weight"] < links.scoring()["strong"]
    assert v2.families()["device"]["cap"] < links.scoring()["strong"]


def test_a_name_alone_stays_below_strong():
    assert v2.families()["name"]["cap"] < links.scoring()["strong"]
    for name in ("full_name", "display_name", "handle_stem"):
        assert v2.signals()[name]["family"] == "name"


def test_mailboxes_fold_aliases_and_leave_out_staff_domains():
    rows = list(v2.mailbox_rows([("U1", "Jo.Doe+x@googlemail.com"), ("U2", "x@mail.hackclub.com"),
                                 ("U3", "nope"), ("U4", "kai@school.edu")], ["hackclub.com"]))

    assert rows == [("U1", "jodoe@gmail.com", "jodoe", "gmail.com"),
                    ("U4", "kai@school.edu", "kai", "school.edu")]


def test_names_skip_bots_and_renamed_deactivated_accounts():
    held = v2.signals()
    for name in ("full_name", "display_name", "handle_stem"):
        sql, _ = v2.evidence(name, held[name], 2)
        assert "NOT" in sql and "is_bot" in sql
        assert "position('deactivateduser' IN lower(" in sql
        assert f">= {v2.SHORTEST_NAME}" in sql


def test_a_handle_stem_drops_trailing_numbers_and_marks():
    sql, _ = v2.evidence("handle_stem", v2.signals()["handle_stem"], 2)
    assert "regexp_replace(lower(handle), '[^a-z]+$', '')" in sql


def test_the_harness_and_the_finder_share_one_mailbox_rule():
    from jobs import score_links
    from lib import mailbox as rule

    assert score_links.mailbox is rule.mailbox
    assert v2.mailbox is rule.mailbox


def test_arrival_evidence_stays_below_strong_on_its_own():
    assert v2.families()["arrival"]["cap"] < links.scoring()["strong"]
    for name in ("created_same_address", "invited_by", "after_ban_address", "after_ban_device"):
        assert v2.signals()[name]["family"] == "arrival"


def test_a_ban_counts_only_while_the_account_stays_deactivated():
    assert "max(at) FILTER (WHERE action = 'user_reactivated') AS back_at" in v2.BANNED
    assert "banned_at > coalesce(back_at, '-infinity'::timestamptz)" in v2.BANNED


def test_after_a_ban_only_a_first_sighting_counts_and_only_on_a_home_address():
    sql, _ = v2.evidence("after_ban_address", v2.signals()["after_ban_address"], 2)

    assert "s.class = 'stable' AND s.hour <= h.banned_at" in sql
    assert "a.first_at > u.banned_at" in sql


def test_onboarding_accounts_that_create_everyone_are_not_inviters():
    sql, args = v2.evidence("invited_by", v2.signals()["invited_by"], 2)

    assert "action = 'user_created'" in sql
    assert "WHERE c.people <= %(ceiling)s" in sql
    assert args["ceiling"] == 20


def test_joining_together_needs_the_same_address_within_the_window():
    sql, args = v2.evidence("created_same_address", v2.signals()["created_same_address"], 2)

    assert "JOIN fd.member_joins j" in sql
    assert "b.ip = a.ip" in sql and "make_interval(secs => %(window)s)" in sql
    assert args["window"] == 1800


def test_the_labels_match_the_table_check():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
           / "0185_member_link_v2_label.sql").read_text()
    for name in v2.labels():
        assert f"'{name}'" in sql


def test_household_and_classroom_lower_the_score_and_staff_test_only_labels():
    held = v2.labels()

    assert held["household"]["weight"] < 0
    assert held["classroom"]["weight"] < 0
    assert "weight" not in held["staff_test"]
    assert "score" not in v2.STAFF_TEST


def test_a_word_list_becomes_one_pattern_and_an_empty_one_matches_nothing():
    assert v2.pattern(["school", "k12"]) == "(school|k12)"
    assert v2.pattern([]) == "a^"


def test_staff_members_are_the_accounts_with_a_staff_mailbox():
    rows = list(v2.staff_members([("U1", "x+test@mail.hackclub.com"), ("U2", "y@gmail.com"),
                                  ("U3", None)], ["hackclub.com"]))
    assert rows == [("U1",)]


def test_a_household_needs_one_home_line_a_shared_surname_and_two_first_names():
    assert "p.signals ? 'ip_stable'" in v2.HOUSEHOLD
    assert "'^.*[[:space:]]'" in v2.HOUSEHOLD
    assert "split_part(lower(btrim(a.real_name)), ' ', 1) <>" in v2.HOUSEHOLD


def test_a_label_change_is_written_like_any_other_change():
    assert "label = EXCLUDED.label" in v2.LAND
    assert "EXCLUDED.label)" in v2.LAND



def test_every_temp_table_is_analysed_before_it_is_joined():
    import inspect

    gathered = inspect.getsource(v2.gather)
    passed = inspect.getsource(v2.run)
    for table in ("sighting", "mailbox", "staff_member"):
        assert f'"ANALYZE {table}"' in gathered, table
    for table in ("shared_ip", "link_part", "link_pass"):
        assert f'"ANALYZE {table}"' in passed, table


def test_signals_are_grouped_by_pair_not_looked_up_per_pair():
    assert "FROM best b\n        WHERE b.a_user_id = p.a_user_id" not in v2.PASS
    assert "GROUP BY b.a_user_id, b.b_user_id" in v2.PASS


def test_a_shared_inbox_counts_however_many_accounts_use_it():
    assert v2.signals()["mailbox_alias"]["crowd_ceiling"] >= 100


def test_a_device_build_counts_only_when_few_members_use_it():
    assert v2.signals()["device_agent"]["crowd_ceiling"] <= 5


def test_a_shared_name_only_backs_other_evidence_up():
    for name in ("full_name", "display_name", "handle_stem"):
        assert v2.signals()[name]["corroborating"] is True, name


def test_a_vpn_exit_few_people_used_is_network_evidence():
    held = v2.signals()
    sql, args = v2.evidence("ip_shared_exit", held["ip_shared_exit"], 2)

    assert "class IN ('vpn', 'hosting', 'tor')" in sql and "FROM sighting" in sql
    assert args["ceiling"] <= 10
    assert held["ip_shared_exit"]["family"] == "network"
    assert held["ip_shared_exit"]["weight"] < links.scoring()["floor"]


def test_repeated_addresses_earn_a_bonus_for_homes_and_for_exits():
    assert ("ip_many", "ip_stable") in v2.REPEATED
    assert ("ip_shared_exits", "ip_shared_exit") in v2.REPEATED
    assert "WHERE signal = %(single)s" in v2.MANY
