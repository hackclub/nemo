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
IPINFO_FILE = "ipinfo_lite.mmdb"
REFRESH_SECONDS = 24 * 3600
DOWNLOAD_TIMEOUT = 120
BATCH = 20000
STALE_DAYS = 30
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

STALE_SQL = """
SELECT ip_prefix FROM fd.ip_network
WHERE classified_at < now() - make_interval(days => %(stale)s)
   OR (source = 'default' AND classified_at < now() - make_interval(days => %(retry)s))
ORDER BY classified_at
LIMIT %(batch)s
"""

TOR_SQL = """
SELECT DISTINCT context->>'ip_address'
FROM slack.audit_event
WHERE action = 'anomaly'
  AND payload->'details'->'reason' ? 'tor'
  AND context->>'ip_address' IS NOT NULL
"""

LAND_SQL = """
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


def network_classes(held=None):
    return (held or catalogue()).get("network_classes", {})


def as_network(value):
    return ipaddress.ip_network(str(value), strict=False)


def prefix_of(address):
    held = ipaddress.ip_address(str(address).split("/")[0])
    return ipaddress.ip_network(f"{held}/{24 if held.version == 4 else 64}", strict=False)


def read_ranges(text):
    found = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            found.append(ipaddress.ip_network(line, strict=False))
        except ValueError:
            continue
    return found


def fetched(name, url, cache_dir=CACHE_DIR, max_age=REFRESH_SECONDS):
    path = cache_dir / name
    if path.exists() and time.time() - path.stat().st_mtime < max_age:
        return path
    cache_dir.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(f"{name}.partial")
    try:
        with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT) as response, open(partial, "wb") as out:
            shutil.copyfileobj(response, out)
    except OSError as failure:
        if path.exists():
            print(f"{SOURCE}: could not refresh {name}, using the copy from "
                  f"{time.strftime('%Y-%m-%d', time.gmtime(path.stat().st_mtime))}: {failure}")
            return path
        raise
    partial.replace(path)
    return path


def asn_number(value):
    text = str(value or "").upper()
    if text.startswith("AS"):
        text = text[2:]
    return int(text) if text.isdigit() else None


def ipinfo_lookup(reader):
    def lookup(network):
        found = reader.get(str(network.network_address)) or {}
        return {"asn": asn_number(found.get("asn")), "network": found.get("as_name") or None,
                "country": found.get("country_code") or None}
    return lookup


def curated_class(asn, network, classes):
    named = (network or "").lower()
    for name in CURATED_ORDER:
        entry = classes.get(name) or {}
        if asn is not None and asn in entry.get("asns", []):
            return name
        if named and any(one.lower() in named for one in entry.get("names", [])):
            return name
    return None


def classify(network, tor, lists, classes, lookup):
    found = lookup(network)
    asn, name, country = found.get("asn"), found.get("network"), found.get("country")
    picked = curated_class(asn, name, classes)
    if network in tor:
        decided = ("tor", "anomaly")
    elif picked == "vpn":
        decided = ("vpn", "curated")
    elif lists["vpn"].overlaps(network):
        decided = ("vpn", "lists_vpn")
    elif picked == "hosting":
        decided = ("hosting", "curated")
    elif lists["hosting"].overlaps(network):
        decided = ("hosting", "lists_vpn")
    elif picked == "rotating":
        decided = ("rotating", "curated")
    else:
        decided = ("stable", "ipinfo" if asn is not None else "default")
    return (str(network), asn, name, country, *decided)


def tor_prefixes(conn):
    found = set()
    for (address,) in conn.execute(TOR_SQL).fetchall():
        try:
            found.add(prefix_of(address))
        except ValueError:
            continue
    return found


def pending(conn):
    held = [row[0] for row in conn.execute(PENDING_SQL, (BATCH,)).fetchall()]
    if len(held) < BATCH:
        held += [row[0] for row in conn.execute(
            STALE_SQL, {"stale": STALE_DAYS, "retry": DEFAULT_RETRY_DAYS,
                        "batch": BATCH - len(held)}).fetchall()]
    return [as_network(one) for one in held]


def run(conn):
    token = os.environ.get("IPINFO_TOKEN", "").strip()
    if not token:
        print(f"{SOURCE}: IPINFO_TOKEN is not set, network classes wait for it")
        return 0

    classes = network_classes()
    with ingest_run(conn, SOURCE) as counts:
        networks = pending(conn)
        if not networks:
            return 0
        lists = {name: Ranges(read_ranges(fetched(f"lists_vpn_{name}.txt", url).read_text()))
                 for name, url in LISTS_VPN.items()}
        tor = tor_prefixes(conn)
        reader = maxminddb.open_database(str(fetched(IPINFO_FILE, IPINFO_LITE.format(token=token))))
        try:
            lookup = ipinfo_lookup(reader)
            rows = [classify(network, tor, lists, classes, lookup) for network in networks]
        finally:
            reader.close()
        with conn.cursor() as cur:
            cur.executemany(LAND_SQL, rows)
        conn.commit()
        counts.rows_in = len(rows)

    tally = {}
    for row in rows:
        tally[row[4]] = tally.get(row[4], 0) + 1
    print(f"{SOURCE}: {len(rows)} prefix(es) classified ("
          + ", ".join(f"{name} {tally[name]}" for name in CLASSES if name in tally) + ")")
    return len(rows)
