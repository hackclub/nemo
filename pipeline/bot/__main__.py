import argparse
import logging
import os
import signal
import sys
import threading

from dotenv import load_dotenv
from slack_bolt.adapter.socket_mode import SocketModeHandler

from bot import APPS, NEEDS, nemo, shroud
from bot.engine import session, shutdown
from bot.nemo import app as nemo_app
from bot.shroud import app as shroud_app
from lib.config import DATABASE
from lib.db import SeededDeployment, refuse_if_seeded
from lib.paths import ENV_FILE

log = logging.getLogger("bot")

BUILD = {
    "shroud": (shroud.build, shroud_app.app_token),
    "nemo": (nemo.build, nemo_app.app_token),
}


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
    wanted = DATABASE + ["PIPELINE_DB_USER", "PIPELINE_DB_PASSWORD"]
    for name in apps:
        wanted += NEEDS[name]
    return [name for name in wanted if not os.environ.get(name)]


def start(name):
    build, token = BUILD[name]
    handler = SocketModeHandler(build(), token())
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

    running = [start(name) for name in apps]
    stopping = threading.Event()

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
