import ipaddress
import os
import shutil
import tempfile
import time
import urllib.request
from bisect import bisect_right
from pathlib import Path

import maxminddb
import yaml

from lib.db import ingest_run
from lib.paths import DB_DIR

SOURCE = "ip_networks"
SIGNALS_FILE = DB_DIR / "alt_signals.yml"
CACHE_DIR = Path(tempfile.gettempdir()) / "mnemosyne-networks"
LISTS_VPN = {
    "vpn": "https://raw.githubusercontent.com/X4BNet/lists_vpn/main/output/vpn/ipv4.txt",
    "hosting": "https://raw.githubusercontent.com/X4BNet/lists_vpn/main/output/datacenter/ipv4.txt",
}
IPINFO_LITE = "https://ipinfo.io/data/ipinfo_lite.mmdb?token={token}"
TOR_EXIT_LISTS = (
    "https://check.torproject.org/torbulkexitlist",
    "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/tor_exits.ipset",
)
TOR_EXIT_FILE = "tor_exits.txt"
IPINFO_FILE = "ipinfo_lite.mmdb"
REFRESH_SECONDS = 24 * 3600
DOWNLOAD_TIMEOUT = 120
BATCH = 20000
STALE_DAYS = 30
RECENT_HOURS = 24
CATCH_UP_SLICE = "catch_up"
DEFAULT_RETRY_DAYS = 1
CLASSES = ("stable", "rotating", "vpn", "hosting", "tor")
CURATED_ORDER = ("vpn", "hosting", "rotating")

PENDING_SQL = """
SELECT DISTINCT e.ip_prefix
FROM fd.login_event e
WHERE e.ip_prefix IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM fd.ip_network n WHERE n.ip_prefix = e.ip_prefix)
LIMIT %s
"""

RECENT_PENDING_SQL = """
SELECT DISTINCT e.ip_prefix
FROM fd.login_event e
WHERE e.ip_prefix IS NOT NULL
  AND e.updated_at > now() - make_interval(hours => %s)
  AND NOT EXISTS (SELECT 1 FROM fd.ip_network n WHERE n.ip_prefix = e.ip_prefix)
LIMIT %s
"""

CATCH_UP_DUE_SQL = """
SELECT NOT EXISTS (
    SELECT 1 FROM raw.ingest_run
    WHERE source = %s AND slice_key = %s AND status = 'ok' AND rows_in < %s
      AND started_at > now() - make_interval(secs => %s)
)
"""

STALE_SQL = """
SELECT ip_prefix FROM (
    (SELECT ip_prefix, classified_at FROM fd.ip_network
     WHERE classified_at < now() - make_interval(days => %(stale)s)
     ORDER BY classified_at
     LIMIT %(batch)s)
    UNION
    (SELECT ip_prefix, classified_at FROM fd.ip_network
     WHERE source = 'default' AND classified_at < now() - make_interval(days => %(retry)s)
     ORDER BY classified_at
     LIMIT %(batch)s)
) due
ORDER BY classified_at
LIMIT %(batch)s
"""

TOR_SQL = """
SELECT DISTINCT host(ip)
FROM slack.audit_event
WHERE action = 'anomaly'
  AND payload->'details'->'reason' ? 'tor'
  AND ip IS NOT NULL
"""

USED_EXITS_SQL = "SELECT DISTINCT host(ip) FROM fd.login_event WHERE ip = ANY(%s::inet[])"

RETAG_SQL = "SELECT ip_prefix FROM fd.ip_network WHERE ip_prefix = ANY(%s::inet[]) AND class <> 'tor'"

UPSERT_SQL = """
INSERT INTO fd.ip_network (ip_prefix, asn, network, country, class, source, classified_at)
VALUES (%s, %s, %s, %s, %s, %s, now())
ON CONFLICT (ip_prefix) DO UPDATE SET
    asn = EXCLUDED.asn,
    network = EXCLUDED.network,
    country = EXCLUDED.country,
    class = EXCLUDED.class,
    source = EXCLUDED.source,
    classified_at = EXCLUDED.classified_at
"""


class Ranges:
    def __init__(self, networks):
        spans = sorted((int(one.network_address), int(one.broadcast_address))
                       for one in networks if one.version == 4)
        merged = []
        for start, end in spans:
            if merged and start <= merged[-1][1] + 1:
                merged[-1][1] = max(merged[-1][1], end)
            else:
                merged.append([start, end])
        self.starts = [start for start, _ in merged]
        self.ends = [end for _, end in merged]

    def __len__(self):
        return len(self.starts)

    def overlaps(self, network):
        if network.version != 4:
            return False
        low, high = int(network.network_address), int(network.broadcast_address)
        at = bisect_right(self.starts, high) - 1
        return at >= 0 and self.ends[at] >= low


def catalogue():
    return yaml.safe_load(SIGNALS_FILE.read_text())


def network_classes(signals=None):
    return (signals or catalogue()).get("network_classes", {})


def as_network(value):
    return ipaddress.ip_network(str(value), strict=False)


def prefix_of(address):
    ip = ipaddress.ip_address(str(address).split("/")[0])
    return ipaddress.ip_network(f"{ip}/{24 if ip.version == 4 else 64}", strict=False)


def read_ranges(text):
    networks = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            networks.append(ipaddress.ip_network(line, strict=False))
        except ValueError:
            continue
    return networks


def download_cached(name, urls, cache_dir=CACHE_DIR, max_age=REFRESH_SECONDS):
    path = cache_dir / name
    if path.exists() and time.time() - path.stat().st_mtime < max_age:
        return path
    cache_dir.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(f"{name}.partial")
    failure = None
    for url in (urls,) if isinstance(urls, str) else urls:
        try:
            with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT) as response, open(partial, "wb") as out:
                shutil.copyfileobj(response, out)
        except OSError as error:
            failure = error
            continue
        partial.replace(path)
        return path
    if path.exists():
        print(f"{SOURCE}: could not refresh {name}, using the copy from "
              f"{time.strftime('%Y-%m-%d', time.gmtime(path.stat().st_mtime))}: {failure}")
        return path
    raise failure


def asn_number(value):
    text = str(value or "").upper()
    if text.startswith("AS"):
        text = text[2:]
    return int(text) if text.isdigit() else None


def ipinfo_lookup(reader):
    def lookup(network):
        record = reader.get(str(network.network_address)) or {}
        return {"asn": asn_number(record.get("asn")), "network": record.get("as_name") or None,
                "country": record.get("country_code") or None}
    return lookup


def curated_class(asn, network, classes):
    network_name = (network or "").lower()
    for name in CURATED_ORDER:
        entry = classes.get(name) or {}
        if asn is not None and asn in entry.get("asns", []):
            return name
        if network_name and any(one.lower() in network_name for one in entry.get("names", [])):
            return name
    return None


def classify(network, tor, lists, classes, lookup):
    info = lookup(network)
    asn, name, country = info.get("asn"), info.get("network"), info.get("country")
    curated = curated_class(asn, name, classes)
    if network in tor:
        classification = ("tor", tor[network])
    elif curated == "vpn":
        classification = ("vpn", "curated")
    elif lists["vpn"].overlaps(network):
        classification = ("vpn", "lists_vpn")
    elif curated == "hosting":
        classification = ("hosting", "curated")
    elif lists["hosting"].overlaps(network):
        classification = ("hosting", "lists_vpn")
    elif curated == "rotating":
        classification = ("rotating", "curated")
    else:
        classification = ("stable", "ipinfo" if asn is not None else "default")
    return (str(network), asn, name, country, *classification)


def tor_exit_addresses():
    try:
        path = download_cached(TOR_EXIT_FILE, TOR_EXIT_LISTS)
    except OSError as failure:
        print(f"{SOURCE}: could not fetch the Tor exit list, Tor comes from Slack anomalies only: {failure}")
        return []
    return [str(one.network_address) for one in read_ranges(path.read_text()) if one.num_addresses == 1]


def tor_prefixes(conn, exit_addresses=()):
    found = [(address, "tor_list") for (address,) in
             (conn.execute(USED_EXITS_SQL, (list(exit_addresses),)).fetchall() if exit_addresses else [])]
    found += [(address, "anomaly") for (address,) in conn.execute(TOR_SQL).fetchall()]
    prefixes = {}
    for address, source in found:
        try:
            prefixes[prefix_of(address)] = source
        except ValueError:
            continue
    return prefixes


def retagged(conn, tor, already):
    if not tor:
        return []
    rows = conn.execute(RETAG_SQL, ([str(one) for one in tor],)).fetchall()
    return [as_network(row[0]) for row in rows if as_network(row[0]) not in already]


def catch_up_due(conn):
    return conn.execute(CATCH_UP_DUE_SQL, (SOURCE, CATCH_UP_SLICE, BATCH, REFRESH_SECONDS)).fetchone()[0]


def pending(conn, catch_up=False):
    found = (conn.execute(PENDING_SQL, (BATCH,)) if catch_up
             else conn.execute(RECENT_PENDING_SQL, (RECENT_HOURS, BATCH)))
    prefixes = [row[0] for row in found.fetchall()]
    if len(prefixes) < BATCH:
        prefixes += [row[0] for row in conn.execute(
            STALE_SQL, {"stale": STALE_DAYS, "retry": DEFAULT_RETRY_DAYS,
                        "batch": BATCH - len(prefixes)}).fetchall()]
    return [as_network(one) for one in prefixes]


def run(conn):
    token = os.environ.get("IPINFO_TOKEN", "").strip()
    if not token:
        print(f"{SOURCE}: IPINFO_TOKEN is not set, network classes wait for it")
        return 0

    classes = network_classes()
    catch_up = catch_up_due(conn)
    with ingest_run(conn, SOURCE, slice_key=CATCH_UP_SLICE if catch_up else None) as counts:
        tor = tor_prefixes(conn, tor_exit_addresses())
        networks = pending(conn, catch_up)
        networks += retagged(conn, tor, set(networks))
        if not networks:
            return 0
        lists = {name: Ranges(read_ranges(download_cached(f"lists_vpn_{name}.txt", url).read_text()))
                 for name, url in LISTS_VPN.items()}
        reader = maxminddb.open_database(str(download_cached(IPINFO_FILE, IPINFO_LITE.format(token=token))))
        try:
            lookup = ipinfo_lookup(reader)
            rows = [classify(network, tor, lists, classes, lookup) for network in networks]
        finally:
            reader.close()
        with conn.cursor() as cur:
            cur.executemany(UPSERT_SQL, rows)
        conn.commit()
        counts.rows_in = len(rows)

    class_counts = {}
    for row in rows:
        class_counts[row[4]] = class_counts.get(row[4], 0) + 1
    print(f"{SOURCE}: {len(rows)} prefix(es) classified ("
          + ", ".join(f"{name} {class_counts[name]}" for name in CLASSES if name in class_counts) + ")")
    return len(rows)
