import argparse
import logging
import os
import signal
import sys
import threading

from dotenv import load_dotenv
from slack_bolt.adapter.socket_mode import SocketModeHandler

from bot import APPS, NEEDS
from bot.engine import session, shutdown
from bot.nemo import app as nemo_app
from bot.nemo import sweep, watch
from bot.relay import Relay
from bot.shroud import app as shroud_app
from lib.config import DATABASE
from lib.db import SeededDeployment, refuse_if_seeded
from lib.paths import ENV_FILE

log = logging.getLogger("bot")


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="nemo bot")
    parser.add_argument(
        "apps",
        nargs="*",
        choices=APPS,
        help="which app to run. both, unless you name one",
    )
    return parser.parse_args(argv)


def needed(apps):
    wanted = list(DATABASE)
    for name in apps:
        wanted += NEEDS[name]
    return [name for name in wanted if not os.environ.get(name)]


def wire(apps, relay):
    built = {}
    if "shroud" in apps:
        built["shroud"] = (shroud_app.build(relay.taken), shroud_app.app_token())
        relay.shroud_client = built["shroud"][0].client
    if "nemo" in apps:
        built["nemo"] = (nemo_app.build(relay.answered), nemo_app.app_token())
        relay.nemo_client = built["nemo"][0].client
    return built


def start(name, app, token):
    handler = SocketModeHandler(app, token)
    thread = threading.Thread(target=handler.start, name=name, daemon=True)
    thread.start()
    log.info("%s connected", name)
    return handler


def main(argv=None):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    load_dotenv(ENV_FILE)

    apps = parse_args(sys.argv[1:] if argv is None else argv).apps or list(APPS)

    gone = needed(apps)
    if gone:
        print(
            f"bot: {', '.join(apps)} needs {len(gone)} variable(s) that are not set: "
            f"{', '.join(gone)}",
            file=sys.stderr,
        )
        print("run `nemo doctor bot` for the whole picture", file=sys.stderr)
        return 78

    try:
        with session() as conn:
            refuse_if_seeded(conn)
    except SeededDeployment as refusal:
        print(f"bot: {refusal}", file=sys.stderr)
        shutdown()
        return 78

    relay = Relay()
    built = wire(apps, relay)
    running = [start(name, *made) for name, made in built.items()]
    stopping = threading.Event()

    if built:
        watch.start(relay, stopping)
        sweep.start(relay, stopping)

    def stop(*_):
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    log.info("bot: up, %s", " and ".join(apps))
    stopping.wait()

    for handler in running:
        handler.close()
    shutdown()
    log.info("bot: stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
