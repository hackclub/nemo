import argparse
import logging
import os
import signal
import sys
import threading

from dotenv import load_dotenv
from slack_bolt.adapter.socket_mode import SocketModeHandler

from bot import APPS, NEEDS, NEMO, RELAY
from bot.core import session, shutdown
from lib.config import DATABASE
from lib.db import SeededDeployment, refuse_if_seeded
from lib.heartbeat import heartbeat_loop
from lib.paths import ENV_FILE

log = logging.getLogger("bot")

WORKER = "bot"


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="nemo bot")
    parser.add_argument(
        "apps",
        nargs="*",
        choices=APPS,
        help="app to run; both if unspecified",
    )
    return parser.parse_args(argv)


def needed(apps):
    wanted = list(DATABASE)
    for name in apps:
        wanted += NEEDS[name]
    return [name for name in wanted if not os.environ.get(name)]


def worker(apps):
    return ".".join([WORKER] + sorted(apps))


def app_list(apps):
    return " and ".join(apps)


def wire_relay(built, sides):
    from bot.relay import app as relay_app
    from bot.relay.messages import MessageRelay

    relay = MessageRelay()
    app = relay_app.build(relay.taken)
    relay.client = app.client
    built[RELAY] = (app, relay_app.app_token())
    sides[RELAY] = relay


def wire_nemo(built, sides):
    from bot.nemo import app as nemo_app
    from bot.nemo.case_channel import CaseChannel

    case_channel = CaseChannel()
    app = nemo_app.build(case_channel.answered)
    case_channel.client = app.client
    built[NEMO] = (app, nemo_app.app_token())
    sides[NEMO] = case_channel


def wire(apps):
    built, sides = {}, {}
    if RELAY in apps:
        wire_relay(built, sides)
    if NEMO in apps:
        wire_nemo(built, sides)
    return built, sides


def start_loops(sides, stopping):
    if RELAY in sides:
        from bot.relay import loop as relay_loop

        relay_loop.start(sides[RELAY], stopping)
    if NEMO in sides:
        from bot.nemo import loop as nemo_loop

        nemo_loop.start(sides[NEMO], stopping)


def start(name, app, token):
    handler = SocketModeHandler(app, token)
    thread = threading.Thread(target=handler.start, name=name, daemon=True)
    thread.start()
    log.info("%s connected", name)
    return handler


def main(argv=None):
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(name)s %(message)s",
    )
    load_dotenv(ENV_FILE)

    apps = parse_args(sys.argv[1:] if argv is None else argv).apps or list(APPS)

    gone = needed(apps)
    if gone:
        print(
            f"bot: {', '.join(apps)} needs {len(gone)} variable(s) that are not set: "
            f"{', '.join(gone)}",
            file=sys.stderr,
        )
        print("Run `nemo doctor bot` for full diagnostics.", file=sys.stderr)
        return 78

    try:
        with session() as conn:
            refuse_if_seeded(conn)
    except SeededDeployment as refusal:
        print(f"bot: {refusal}", file=sys.stderr)
        shutdown()
        return 78

    built, sides = wire(apps)
    running = [start(name, *made) for name, made in built.items()]
    stopping = threading.Event()

    start_loops(sides, stopping)

    def stop(*_):
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    log.info("bot: up, %s", " and ".join(apps))
    with heartbeat_loop(worker(apps), lambda: app_list(apps)):
        stopping.wait()

    for handler in running:
        handler.close()
    shutdown()
    log.info("bot: stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
