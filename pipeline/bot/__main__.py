import argparse
import logging
import os
import signal
import sys
import threading

from dotenv import load_dotenv
from slack_bolt.adapter.socket_mode import SocketModeHandler

from bot import APPS, NEEDS, NEMO, SHROUD
from bot.core import session, shutdown
from lib.config import DATABASE
from lib.db import SeededDeployment, refuse_if_seeded
from lib.heartbeat import beating
from lib.paths import ENV_FILE

log = logging.getLogger("bot")

WORKER = "bot"


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


def worker(apps):
    return ".".join([WORKER] + sorted(apps))


def said(apps):
    return " and ".join(apps)


def wire_shroud(built, sides):
    from bot.shroud import app as shroud_app
    from bot.shroud.carrier import Carrier

    carrier = Carrier()
    app = shroud_app.build(carrier.taken)
    carrier.client = app.client
    built[SHROUD] = (app, shroud_app.app_token())
    sides[SHROUD] = carrier


def wire_nemo(built, sides):
    from bot.nemo import app as nemo_app
    from bot.nemo.desk import Desk

    desk = Desk()
    app = nemo_app.build(desk.answered)
    desk.client = app.client
    built[NEMO] = (app, nemo_app.app_token())
    sides[NEMO] = desk


def wire(apps):
    built, sides = {}, {}
    if SHROUD in apps:
        wire_shroud(built, sides)
    if NEMO in apps:
        wire_nemo(built, sides)
    return built, sides


def start_loops(sides, stopping):
    if SHROUD in sides:
        from bot.shroud import loop as shroud_loop

        shroud_loop.start(sides[SHROUD], stopping)
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

    built, sides = wire(apps)
    running = [start(name, *made) for name, made in built.items()]
    stopping = threading.Event()

    start_loops(sides, stopping)

    def stop(*_):
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    log.info("bot: up, %s", " and ".join(apps))
    with beating(worker(apps), lambda: said(apps)):
        stopping.wait()

    for handler in running:
        handler.close()
    shutdown()
    log.info("bot: stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
