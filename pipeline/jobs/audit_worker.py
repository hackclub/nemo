import os
import signal
import threading

from dotenv import load_dotenv

from ingest.access_logs_pull import backfill as backfill_access_logs
from ingest.access_logs_pull import run as walk_access_logs
from ingest.audit_logs_pull import backfill_next, unknown_backfill_sets
from ingest.audit_logs_pull import tail as walk_tail
from ingest.ip_cohorts import run as refresh_cohorts
from ingest.ip_networks import run as classify_networks
from ingest.member_links import run as refresh_links
from ingest.member_clusters import run as refresh_clusters
from ingest.useragent_reparse import run as reread_agents
from lib.db import (
    AlreadyRunningError,
    SeededDeployment,
    SyncCancelled,
    cancel_scope,
    connect,
    refuse_if_seeded,
    set_worker,
    instance_lock,
    clear_stale_sessions,
)
from lib.heartbeat import heartbeat_loop
from lib.paths import ENV_FILE
from lib.proxy_client import ProxyError

WORKER = "audit_worker"
DEFAULT_TAIL_SECONDS = 60
DEFAULT_BACKFILL_SECONDS = 120
DEFAULT_ACCESS_SECONDS = 60
DEFAULT_ACCESS_BACKFILL_SECONDS = 60
DEFAULT_COHORT_SECONDS = 900
DEFAULT_NETWORK_SECONDS = 900
DEFAULT_LINK_SECONDS = 1800
DEFAULT_CLUSTER_SECONDS = 3600
DEFAULT_AGENT_SECONDS = 3600
JOIN_TIMEOUT = 10
BUSY_POLL_SECONDS = 2
REFUSED_BACKOFF_SECONDS = 900

REFUSALS = ("invalid_auth", "auditlogs:read", "not_allowed_token_type", "audit 403", "audit 401")


def seconds(name, fallback):
    return int(os.environ.get(name, "") or fallback)


LANE_SWITCHES = {
    "backfill": ("AUDIT_BACKFILL", True),
    "access_backfill": ("AUDIT_ACCESS_BACKFILL", False),
}
OFF_VALUES = ("0", "off", "no", "false")


def lane_enabled(name):
    if name not in LANE_SWITCHES:
        return True
    variable, default = LANE_SWITCHES[name]
    value = os.environ.get(variable, "").strip().lower()
    if not value:
        return default
    return value not in OFF_VALUES


def refused(failure):
    text = str(failure)
    return any(one in text for one in REFUSALS)


LANES = (
    ("tail", walk_tail, "AUDIT_TAIL_SECONDS", DEFAULT_TAIL_SECONDS, True),
    ("backfill", backfill_next, "AUDIT_BACKFILL_SECONDS", DEFAULT_BACKFILL_SECONDS, True),
    ("access", walk_access_logs, "AUDIT_ACCESS_SECONDS", DEFAULT_ACCESS_SECONDS, True),
    ("access_backfill", backfill_access_logs, "AUDIT_ACCESS_BACKFILL_SECONDS",
     DEFAULT_ACCESS_BACKFILL_SECONDS, True),
    ("cohorts", refresh_cohorts, "AUDIT_COHORT_SECONDS", DEFAULT_COHORT_SECONDS, False),
    ("networks", classify_networks, "AUDIT_NETWORK_SECONDS", DEFAULT_NETWORK_SECONDS, True),
    ("links", refresh_links, "AUDIT_LINK_SECONDS", DEFAULT_LINK_SECONDS, False),
    ("clusters", refresh_clusters, "AUDIT_CLUSTER_SECONDS", DEFAULT_CLUSTER_SECONDS, False),
    ("agents", reread_agents, "AUDIT_AGENT_SECONDS", DEFAULT_AGENT_SECONDS, True),
)


def note(state):
    return ", ".join(f"{name} {state[name]}" for name, *_ in LANES)


def lane(name, work, state, stopping, poll, drains=True):
    def loop():
        while not stopping.is_set():
            moved = 0
            try:
                with connect() as conn, cancel_scope(stopping.is_set):
                    moved = work(conn)
                state[name] = f"idle after {moved}" if moved else "idle"
            except SyncCancelled:
                state[name] = "stopped mid-pass"
                return
            except ProxyError as failure:
                if refused(failure):
                    state[name] = "refused, the token cannot read the audit logs"
                    print(f"{WORKER}: the {name} lane is refused, holding off: {failure}")
                    if stopping.wait(REFUSED_BACKOFF_SECONDS):
                        return
                    continue
                state[name] = f"failed, {type(failure).__name__}"
                print(f"{WORKER}: the {name} lane failed: {failure}")
            except Exception as failure:  # noqa: BLE001
                state[name] = f"failed, {type(failure).__name__}"
                print(f"{WORKER}: the {name} lane failed, trying again after the poll: {failure}")
            if stopping.wait(BUSY_POLL_SECONDS if moved and drains else poll):
                return
        state[name] = "stopped"

    thread = threading.Thread(target=loop, name=f"{WORKER}-{name}", daemon=True)
    thread.start()
    return thread


def main():
    load_dotenv(ENV_FILE)
    set_worker(WORKER)
    try:
        with instance_lock(WORKER):
            return serve()
    except AlreadyRunningError as clash:
        print(f"{WORKER}: {clash}")
        return 1


def wanted_lanes():
    enabled = []
    for spec in LANES:
        name = spec[0]
        if lane_enabled(name):
            enabled.append(spec)
        else:
            print(f"{WORKER}: {LANE_SWITCHES[name][0]} is off, the {name} lane will not run")
    if lane_enabled("backfill"):
        unknown = unknown_backfill_sets()
        if unknown:
            print(f"{WORKER}: AUDIT_BACKFILL_SETS has unknown set names, skipping: {', '.join(unknown)}")
    return tuple(enabled)


def serve():
    with connect() as conn:
        try:
            refuse_if_seeded(conn)
        except SeededDeployment as refusal:
            print(f"{WORKER}: {refusal}")
            raise SystemExit(1) from refusal
        for orphan, source in clear_stale_sessions(conn):
            print(f"{WORKER}: swept run {orphan} ({source}), left running by an earlier boot")

    lanes = wanted_lanes()
    enabled_names = {name for name, *_ in lanes}
    stopping = threading.Event()
    state = {name: "starting" if name in enabled_names else "off" for name, *_ in LANES}

    def stop(*_):
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(f"{WORKER}: {len(lanes)} lane(s) running independently")
    with heartbeat_loop(WORKER, lambda: note(state)):
        running = [lane(name, work, state, stopping, seconds(var, fallback), drains)
                   for name, work, var, fallback, drains in lanes]
        stopping.wait()
        for thread in running:
            thread.join(timeout=JOIN_TIMEOUT)

    print(f"{WORKER}: stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
