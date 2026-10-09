import contextlib
import pathlib

from ingest import member_links as links

WHOLE = 1000


def rarity(crowd, whole=WHOLE):
    import math
    if whole <= 2 or crowd <= 1:
        return 1.0
    if crowd >= whole:
        return 0.0
    return min(1.0, max(0.0, math.log(whole / crowd) / math.log(whole / 2)))


def score_for(name, crowd, whole=WHOLE):
    return links.signals()[name]["weight"] * rarity(crowd, whole)


def test_the_bands_climb():
    marks = links.scoring()
    assert marks["floor"] < marks["strong"] < marks["certain"]


def test_a_school_domain_cannot_link_two_people_on_its_own():
    marks = links.scoring()
    assert score_for("email_domain", 6) < marks["floor"], \
        "six people on one domain is a school, not an alt"
    assert score_for("joined_together", 2) < marks["floor"], \
        "arriving together is a crowd signal, not an identity"


def test_a_pair_is_written_one_way_round_so_it_cannot_be_held_twice():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0149_member_links.sql").read_text()
    assert "CHECK (a_user_id < b_user_id)" in sql
    assert "PRIMARY KEY (a_user_id, b_user_id)" in sql
    assert "least(a.user_id, b.user_id)" in links.PAIRS_SQL


def test_a_verdict_is_held_once_per_pair_in_the_same_order_as_its_link():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
            / "0181_member_link_verdicts.sql").read_text()
    assert "CHECK (a_user_id < b_user_id)" in sql
    assert "UNIQUE (a_user_id, b_user_id)" in sql


def test_the_crowd_ceiling_prunes_before_the_join_not_after_it():
    for sql in (links.PAIRS_SQL, links.TOGETHER_SQL):
        pruned = sql.index("BETWEEN 2 AND %(ceiling)s")
        joined = sql.index("JOIN small b")
        assert pruned < joined, (
            "a value thousands of people share must be dropped before the self-join; "
            "filtering after it materialises n squared rows and the pass never ends")
        assert "FROM small a" in sql


def test_neither_side_of_the_join_reads_the_unpruned_evidence():
    for sql in (links.PAIRS_SQL, links.TOGETHER_SQL):
        assert "FROM ev a" not in sql
        assert "JOIN ev b" not in sql


def test_a_network_many_people_share_is_not_evidence_of_anything():
    held = links.shared()
    assert held["rotates_above"] > 1, "a carrier hands each person a fresh address every time"
    assert held["crowds_above"] > 1, "a vpn exit is one address behind which anybody can stand"
    assert held["min_sightings"] >= 2, "one sighting on an address is a coincidence, not a home"


def test_the_shared_networks_are_worked_out_rather_than_listed_by_hand():
    assert "count(DISTINCT ip)" in links.SHARED_ISP
    assert "count(DISTINCT user_id)" in links.SHARED_ISP
    assert "rotates" in links.SHARED_ISP and "crowds" in links.SHARED_ISP
    for named in ("T-Mobile", "ProtonVPN", "Jio"):
        assert named not in links.SHARED_ISP, "no isp is named in the code"


def test_the_shared_tables_are_gone_when_the_pass_commits():
    assert "ON COMMIT DROP" in links.SHARED_ISP
    assert "ON COMMIT DROP" in links.SHARED_IP


def test_every_signal_belongs_to_a_family_with_a_cap():
    caps = links.families()
    for name, one in links.signals().items():
        assert one["family"] in caps, name
    for family, one in caps.items():
        assert one["cap"] > 0, family


def test_only_identity_evidence_can_reach_certain_alone():
    certain = links.scoring()["certain"]
    for family, one in links.families().items():
        if family != "identity":
            assert one["cap"] < certain, family
    assert links.signals()["mailbox_alias"]["weight"] >= certain


def test_the_family_table_lines_up_signal_by_signal():
    table = links.family_table(links.catalogue())

    assert len({len(column) for column in table.values()}) == 1
    at = table["signals"].index("session_agent")
    assert table["families"][at] == "device"
    assert table["corroborating"][at] is True


def test_each_family_is_capped_before_the_families_are_added():
    assert "least(sum(b.score), f.cap)" in links.PASS
    assert "bool_or(NOT corroborating)" in links.PASS


def test_an_unchanged_link_is_not_written_again():
    assert "IS DISTINCT FROM" in links.LAND
    assert "NOT EXISTS (SELECT 1 FROM link_pass" in links.SWEEP


def test_the_full_rebuild_never_sweeps_a_link_the_live_lane_wrote_after_it_started():
    assert "l.computed_at < now()" in links.SWEEP


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
            self.rowcount = {links.LAND: 4, links.SWEEP: 1}.get(sql, 0)

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

    monkeypatch.setattr(links, "ingest_run", bookkeeping)
    monkeypatch.setattr(links, "mark_shared", lambda _conn, _held: 2)
    monkeypatch.setattr(links, "prepare", lambda _conn, _held: None)
    monkeypatch.setattr(links, "measure", lambda _conn, _held: {"ip_stable": 40})
    monkeypatch.setattr(links, "gather", lambda _conn, _held, _wholes: {"ip_stable": 3})

    assert links.run(Conn()) == 4
    ran[:] = [one for one in ran if one not in ("ANALYZE shared_ip", "ANALYZE link_part", links.KEEP_WHOLE)]
    assert ran[:13] == [links.PASS, links.PASS_INDEX, "ANALYZE link_pass", links.PRESENCE.format(**links.FULL),
                        links.PRESENCE_INDEX,
                        "ANALYZE presence", links.AGAINST, links.STAFF_TEST, links.CLASSROOM, links.HOUSEHOLD,
                        links.BELOW_FLOOR, links.LAND, links.SWEEP]
    assert ran[-1] == "commit"
    assert "9 link(s) kept, 4 written, 1 dropped" in capsys.readouterr().out


def test_the_new_finder_takes_its_network_evidence_from_the_class_aware_signals():
    names = set(links.signals())

    assert {"ip_stable", "ip_same_hour", "ip_many", "ip_hourly", "ip_prefix_stable"} <= names
    assert not {"ip_exact", "ip_prefix"} & names
    assert {"email_domain", "session_agent", "joined_together"} <= names


def test_a_home_range_only_counts_alongside_another_family():
    assert links.signals()["ip_prefix_stable"]["corroborating"] is True


def test_each_signal_reads_the_evidence_built_for_it():
    held = links.signals()

    stable, _ = links.evidence("ip_stable", held["ip_stable"], 2)
    hourly, _ = links.evidence("ip_hourly", held["ip_hourly"], 2)
    domain, _ = links.evidence("email_domain", held["email_domain"], 2)
    together, args = links.evidence("joined_together", held["joined_together"], 2)

    assert "FROM sighting" in stable and "class = 'stable'" in stable
    assert "HAVING sum(s.seen) >= 2" in stable
    assert "'rotating', 'vpn', 'hosting', 'tor'" in hourly and "md5(u.ua)" in hourly
    assert "fd.member_identity" in domain
    assert together == links.TOGETHER_SQL.format(**links.FULL) and args["window"] == 300
    assert links.evidence("nothing", {"weight": 1, "crowd_ceiling": 2}, 2) == (None, None)


def test_an_address_another_isp_rotates_through_is_treated_as_rotating():
    assert ("WHEN EXISTS (SELECT 1 FROM shared_ip s WHERE s.ip = e.ip) THEN 'rotating'"
            in links.SIGHTING.format(**links.FULL))


def test_hourly_evidence_keeps_one_row_per_pair():
    assert set(links.COLLAPSED) == {"ip_same_hour", "ip_hourly", "ip_burst"}
    assert "DISTINCT ON (a_user_id, b_user_id)" in links.COLLAPSED_PART


def test_two_countries_in_one_hour_count_against_a_link_unless_one_is_a_vpn():
    assert links.against()["two_countries"]["weight"] < 0
    assert "s.class NOT IN ('vpn', 'hosting', 'tor')" in links.PRESENCE
    assert "coalesce(e.country, n.country) AS country" in links.SIGHTING
    assert "b.hour = a.hour AND b.country <> a.country" in links.AGAINST


def test_the_country_check_reads_only_the_members_of_candidate_links():
    assert "FROM sighting s" in links.PRESENCE.format(**links.FULL)
    assert "SELECT a_user_id FROM link_pass UNION SELECT b_user_id FROM link_pass" in links.PRESENCE
    assert "fd.login_event" not in links.AGAINST


def test_a_word_for_word_build_is_device_evidence_and_ja4_only_backs_it_up():
    held = links.signals()

    assert held["device_agent"]["family"] == "device"
    assert held["device_agent"]["corroborating"] is True
    assert held["device_ja4"]["corroborating"] is True
    assert held["device_agent"]["crowd_ceiling"] <= 25


def test_device_evidence_reads_the_full_agent_and_the_anomaly_fingerprint():
    held = links.signals()

    agent, _ = links.evidence("device_agent", held["device_agent"], 2)
    ja4, _ = links.evidence("device_ja4", held["device_ja4"], 2)

    assert "u.ua AS value" in agent and f"length(u.ua) >= {links.SHORTEST_AGENT}" in agent
    assert "client_ja4_fingerprint" in ja4 and "action = 'anomaly'" in ja4
    assert "BETWEEN 2 AND %(ceiling)s" in agent


def test_a_shared_build_alone_stays_below_strong():
    held = links.signals()
    assert held["device_agent"]["weight"] < links.scoring()["strong"]
    assert links.families()["device"]["cap"] < links.scoring()["strong"]


def test_a_name_alone_stays_below_strong():
    assert links.families()["name"]["cap"] < links.scoring()["strong"]
    for name in ("full_name", "display_name", "handle_stem"):
        assert links.signals()[name]["family"] == "name"


def test_mailboxes_fold_aliases_and_leave_out_staff_domains():
    rows = list(links.mailbox_rows([("U1", "Jo.Doe+x@googlemail.com"), ("U2", "x@mail.hackclub.com"),
                                 ("U3", "nope"), ("U4", "kai@school.edu")], ["hackclub.com"]))

    assert rows == [("U1", "jodoe@gmail.com", "jodoe", "gmail.com"),
                    ("U4", "kai@school.edu", "kai", "school.edu")]


def test_names_skip_bots_and_renamed_deactivated_accounts():
    held = links.signals()
    for name in ("full_name", "display_name", "handle_stem", "handle_stem_long"):
        sql, _ = links.evidence(name, held[name], 2)
        assert "NOT" in sql and "is_bot" in sql
        assert "position('deactivateduser' IN lower(" in sql
        assert f">= {links.SHORTEST_NAME}" in sql or f">= {links.SHORTEST_LONG_STEM}" in sql


def test_a_handle_stem_drops_trailing_numbers_and_marks():
    sql, _ = links.evidence("handle_stem", links.signals()["handle_stem"], 2)
    assert "regexp_replace(lower(handle), '[^a-z]+$', '')" in sql


def test_the_harness_and_the_finder_share_one_mailbox_rule():
    from jobs import score_links
    from lib import mailbox as rule

    assert score_links.mailbox is rule.mailbox
    assert links.mailbox is rule.mailbox


def test_arrival_evidence_stays_below_strong_on_its_own():
    assert links.families()["arrival"]["cap"] < links.scoring()["strong"]
    for name in ("created_same_address", "invited_by", "after_ban_address", "after_ban_device"):
        assert links.signals()[name]["family"] == "arrival"


def test_a_ban_counts_only_while_the_account_stays_deactivated():
    assert "max(at) FILTER (WHERE action = 'user_reactivated') AS back_at" in links.BANNED
    assert "banned_at > coalesce(back_at, '-infinity'::timestamptz)" in links.BANNED


def test_after_a_ban_only_a_first_sighting_counts_and_only_on_a_home_address():
    sql, _ = links.evidence("after_ban_address", links.signals()["after_ban_address"], 2)

    assert "s.class = 'stable' AND s.hour <= h.banned_at" in sql
    assert "a.first_at > u.banned_at" in sql


def test_onboarding_accounts_that_create_everyone_are_not_inviters():
    sql, args = links.evidence("invited_by", links.signals()["invited_by"], 2)

    assert "action = 'user_created'" in sql
    assert "WHERE c.people <= %(ceiling)s" in sql
    assert args["ceiling"] == 20


def test_joining_together_needs_the_same_address_within_the_window():
    sql, args = links.evidence("created_same_address", links.signals()["created_same_address"], 2)

    assert "JOIN fd.member_joins j" in sql
    assert "b.ip = a.ip" in sql and "make_interval(secs => %(window)s)" in sql
    assert args["window"] == 1800


def test_the_labels_match_the_table_check():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations"
           / "0188_member_link_by_family.sql").read_text()
    for name in links.labels():
        assert f"'{name}'" in sql


def test_household_and_classroom_lower_the_score_and_staff_test_only_labels():
    held = links.labels()

    assert held["household"]["weight"] < 0
    assert held["classroom"]["weight"] < 0
    assert "weight" not in held["staff_test"]
    assert "score" not in links.STAFF_TEST


def test_a_word_list_becomes_one_pattern_and_an_empty_one_matches_nothing():
    assert links.pattern(["school", "k12"]) == "(school|k12)"
    assert links.pattern([]) == "a^"


def test_staff_members_are_the_accounts_with_a_staff_mailbox():
    rows = list(links.staff_members([("U1", "x+test@mail.hackclub.com"), ("U2", "y@gmail.com"),
                                  ("U3", None)], ["hackclub.com"]))
    assert rows == [("U1",)]


def test_a_household_needs_one_home_line_a_shared_surname_and_two_first_names():
    assert "p.signals ? 'ip_stable'" in links.HOUSEHOLD
    assert "'^.*[[:space:]]'" in links.HOUSEHOLD
    assert "split_part(lower(btrim(a.real_name)), ' ', 1) <>" in links.HOUSEHOLD


def test_a_label_change_is_written_like_any_other_change():
    assert "label = EXCLUDED.label" in links.LAND
    assert "EXCLUDED.label)" in links.LAND


def test_every_temp_table_is_analysed_before_it_is_joined():
    import inspect

    prepared = inspect.getsource(links.prepare)
    passed = inspect.getsource(links.run) + inspect.getsource(links.settle)
    for table in ("sighting", "mailbox", "staff_member"):
        assert f'"ANALYZE {table}"' in prepared, table
    for table in ("shared_ip", "link_part", "link_pass"):
        assert f'"ANALYZE {table}"' in passed, table


def test_signals_are_grouped_by_pair_not_looked_up_per_pair():
    assert "FROM best b\n        WHERE b.a_user_id = p.a_user_id" not in links.PASS
    assert "GROUP BY b.a_user_id, b.b_user_id" in links.PASS


def test_a_shared_inbox_counts_however_many_accounts_use_it():
    assert links.signals()["mailbox_alias"]["crowd_ceiling"] >= 100


def test_a_device_build_counts_only_when_few_members_use_it():
    assert links.signals()["device_agent"]["crowd_ceiling"] <= 5


def test_a_shared_name_only_backs_other_evidence_up():
    for name in ("full_name", "display_name", "handle_stem"):
        assert links.signals()[name]["corroborating"] is True, name


def test_a_long_shared_handle_stem_links_on_its_own_but_stays_below_strong():
    held = links.signals()["handle_stem_long"]
    sql, args = links.evidence("handle_stem_long", held, 2)

    assert not held.get("corroborating")
    assert held["family"] == "name"
    assert f">= {links.SHORTEST_LONG_STEM}" in sql and links.SHORTEST_LONG_STEM >= 8
    assert args["ceiling"] >= 14
    assert held["weight"] * 0.8 >= links.scoring()["floor"]
    assert links.families()["name"]["cap"] < links.scoring()["strong"]


def test_a_short_stem_still_only_backs_other_evidence_up():
    assert links.signals()["handle_stem"]["corroborating"] is True


def test_a_vpn_or_mobile_address_in_the_same_hour_with_the_same_browser_reaches_the_floor():
    assert links.signals()["ip_hourly"]["weight"] >= links.scoring()["floor"]


def test_only_precise_evidence_can_make_a_link_on_its_own():
    primary = {name for name, one in links.signals().items() if not one.get("corroborating")}

    assert primary == {"ip_stable", "ip_many", "ip_hourly", "ip_burst", "mailbox_alias", "local_part",
                       "handle_stem_long", "created_same_address", "invited_by",
                       "after_ban_address", "after_ban_device"}


def test_a_home_address_on_a_busy_range_does_not_count():
    sql, _ = links.evidence("ip_stable", links.signals()["ip_stable"], 2)

    assert "HAVING count(DISTINCT user_id) <= 20" in sql
    assert links.signals()["ip_same_hour"]["corroborating"] is True


def test_a_burst_needs_the_same_exit_hour_and_browser_and_joins_in_the_same_week():
    held = links.signals()["ip_burst"]
    sql, args = links.evidence("ip_burst", held, 2)

    assert sql == links.BURST.format(**links.names_for(links.FULL, held, 2))
    assert "JOIN fd.member_joins j" in sql
    assert "make_interval(days => %(window)s)" in sql
    assert "md5(u.ua)" in sql and "'rotating', 'vpn', 'hosting', 'tor'" in sql
    assert args == {"weight": held["weight"], "ceiling": 8, "window": 7}
    assert "{" not in sql
    assert held["weight"] >= links.scoring()["floor"]
    assert "ip_burst" in links.COLLAPSED


def test_only_home_addresses_earn_the_repeat_bonus():
    assert links.REPEATED == (("ip_many", "ip_stable"),)


def test_every_signal_has_evidence_built_for_it():
    for name, settings in links.signals().items():
        if name == links.IP_MANY:
            continue
        sql, _ = links.evidence(name, settings, 2)
        assert sql is not None, name


def test_the_finder_writes_the_links_table_the_web_reads():
    assert "INSERT INTO fd.member_link\n" in links.LAND
    assert "top_signal = EXCLUDED.top_signal" in links.LAND
    assert "DELETE FROM fd.member_link l" in links.SWEEP


def test_the_full_rebuild_keeps_what_the_live_lane_needs():
    import inspect

    passed = inspect.getsource(links.run)
    assert "keep_wholes(conn, wholes)" in passed
    assert "KEEP_SHARED" in inspect.getsource(links.mark_shared)
    assert "rarity(%(whole)s::numeric, k.people)" in links.PAIRS_SQL
    assert "rarity(%(whole)s::numeric, k.people)" in links.TOGETHER_SQL


def test_a_value_too_crowded_to_load_never_pairs_in_the_live_lane():
    live = {**links.FULL, "crowded": "crowded"}
    sql, _ = links.evidence("email_domain", links.signals()["email_domain"], 2, live)
    assert "AND value NOT IN (SELECT value FROM crowded WHERE signal = %(name)s)" in sql
    full, _ = links.evidence("email_domain", links.signals()["email_domain"], 2)
    assert "crowded" not in full


def test_ties_break_by_name_so_a_rebuild_does_not_rewrite_unchanged_links():
    assert "ORDER BY b.score DESC, b.signal" in links.PASS
    assert "ORDER BY score DESC, family" in links.PASS
    assert "ORDER BY a_user_id, b_user_id, signal, score DESC, value" in links.PASS
    assert "ORDER BY a_user_id, b_user_id, score DESC, value" in links.COLLAPSED_PART
