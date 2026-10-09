import ipaddress
import os
import pathlib
import time

import pytest

from ingest import ip_networks as networks

CLASSES = {
    "vpn": {"names": ["Proton AG", "M247"], "asns": [36183]},
    "hosting": {"names": [], "asns": []},
    "rotating": {"names": ["Reliance Jio", "T-Mobile"], "asns": []},
}


def net(text):
    return ipaddress.ip_network(text, strict=False)


def lists(vpn=(), hosting=()):
    return {"vpn": networks.Ranges([net(one) for one in vpn]),
            "hosting": networks.Ranges([net(one) for one in hosting])}


def knows(asn=None, name=None, country=None):
    return lambda _network: {"asn": asn, "network": name, "country": country}


def test_the_classes_match_the_table_check():
    sql = (pathlib.Path(__file__).parents[2] / "db" / "migrations" / "0183_ip_networks.sql").read_text()
    for name in networks.CLASSES:
        assert f"'{name}'" in sql


def test_ranges_merge_and_find_any_overlap_with_a_prefix():
    held = networks.Ranges([net("10.0.0.0/28"), net("10.0.0.8/29"), net("192.168.0.0/16")])

    assert len(held) == 2
    assert held.overlaps(net("10.0.0.0/24"))
    assert held.overlaps(net("192.168.5.0/24"))
    assert not held.overlaps(net("10.0.1.0/24"))
    assert not held.overlaps(net("2001:db8::/64"))


def test_range_lists_skip_blank_comment_and_broken_lines():
    found = networks.read_ranges("# list\n1.2.3.0/24\n\nnot a range\n5.6.7.8 # one host\n")

    assert found == [net("1.2.3.0/24"), net("5.6.7.8/32")]


def test_an_address_folds_into_its_prefix():
    assert networks.prefix_of("1.2.3.4") == net("1.2.3.0/24")
    assert networks.prefix_of("2001:db8::1") == net("2001:db8::/64")
    assert networks.as_network("1.2.3.0/24") == net("1.2.3.0/24")


def test_ipinfo_numbers_read_with_or_without_the_as_prefix():
    assert networks.asn_number("AS13335") == 13335
    assert networks.asn_number("13335") == 13335
    assert networks.asn_number("") is None
    assert networks.asn_number(None) is None


def test_curated_classes_match_on_number_or_on_part_of_the_name():
    assert networks.curated_class(36183, "Akamai Technologies, Inc.", CLASSES) == "vpn"
    assert networks.curated_class(9009, "M247 Europe SRL", CLASSES) == "vpn"
    assert networks.curated_class(55836, "Reliance Jio Infocomm Limited", CLASSES) == "rotating"
    assert networks.curated_class(7922, "Comcast Cable Communications, LLC", CLASSES) is None


def test_tor_beats_every_other_class():
    prefix = net("5.6.7.0/24")

    row = networks.classify(prefix, {prefix}, lists(vpn=["5.6.7.0/24"]), CLASSES, knows(9009, "M247"))

    assert row[4:] == ("tor", "anomaly")


def test_a_vpn_comes_from_the_curated_list_or_lists_vpn():
    curated = networks.classify(net("5.6.7.0/24"), set(), lists(), CLASSES, knows(62371, "Proton AG"))
    listed = networks.classify(net("5.6.7.0/24"), set(), lists(vpn=["5.6.7.128/25"]), CLASSES,
                               knows(7922, "Comcast"))

    assert curated[4:] == ("vpn", "curated")
    assert listed[4:] == ("vpn", "lists_vpn")


def test_datacenters_are_hosting_and_carriers_rotate():
    hosted = networks.classify(net("5.6.7.0/24"), set(), lists(hosting=["5.6.0.0/16"]), CLASSES,
                               knows(16276, "OVH SAS"))
    carrier = networks.classify(net("49.36.0.0/24"), set(), lists(), CLASSES,
                                knows(55836, "Reliance Jio Infocomm Limited", "IN"))

    assert hosted[4:] == ("hosting", "lists_vpn")
    assert carrier == ("49.36.0.0/24", 55836, "Reliance Jio Infocomm Limited", "IN", "rotating", "curated")


def test_everything_else_is_a_stable_line_known_or_not():
    known = networks.classify(net("73.0.0.0/24"), set(), lists(), CLASSES, knows(7922, "Comcast"))
    unknown = networks.classify(net("73.0.0.0/24"), set(), lists(), CLASSES, knows())

    assert known[4:] == ("stable", "ipinfo")
    assert unknown[4:] == ("stable", "default")


def test_a_fresh_download_is_reused_and_a_stale_one_survives_a_failed_refresh(tmp_path, monkeypatch):
    cached = tmp_path / "list.txt"
    cached.write_text("1.2.3.0/24\n")

    def refuse(*_args, **_kwargs):
        raise OSError("offline")

    monkeypatch.setattr(networks.urllib.request, "urlopen", refuse)

    assert networks.fetched("list.txt", "https://example.com", cache_dir=tmp_path) == cached
    old = time.time() - networks.REFRESH_SECONDS - 60
    os.utime(cached, (old, old))
    assert networks.fetched("list.txt", "https://example.com", cache_dir=tmp_path) == cached

    with pytest.raises(OSError):
        networks.fetched("missing.txt", "https://example.com", cache_dir=tmp_path)


def test_nothing_runs_until_the_ipinfo_token_is_set(monkeypatch, capsys):
    monkeypatch.delenv("IPINFO_TOKEN", raising=False)

    assert networks.run(object()) == 0
    assert "IPINFO_TOKEN is not set" in capsys.readouterr().out
