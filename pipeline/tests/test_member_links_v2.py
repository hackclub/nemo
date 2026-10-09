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

        def commit(self):
            ran.append("commit")

    @contextlib.contextmanager
    def bookkeeping(*_args, **_kwargs):
        yield Counts()

    monkeypatch.setattr(v2, "ingest_run", bookkeeping)
    monkeypatch.setattr(links, "mark_shared", lambda _conn, _held: 2)
    monkeypatch.setattr(v2, "gather", lambda _conn, _held: {"ip_stable": 3})

    assert v2.run(Conn()) == 4
    assert ran[:6] == [v2.PASS, v2.PASS_INDEX, v2.AGAINST, v2.BELOW_FLOOR, v2.LAND, v2.SWEEP]
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
    assert "NOT IN ('vpn', 'hosting', 'tor')" in v2.AGAINST
    assert "coalesce(a.country, na.country) <> coalesce(b.country, nb.country)" in v2.AGAINST


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
