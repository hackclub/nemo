import logging
import signal
import sys
import threading

from dotenv import load_dotenv
from slack_bolt.adapter.socket_mode import SocketModeHandler

from bot import nemo, shroud
from bot.engine import session, shutdown
from bot.nemo import app as nemo_app
from bot.shroud import app as shroud_app
from lib.config import missing
from lib.db import SeededDeployment, refuse_if_seeded
from lib.paths import ENV_FILE

log = logging.getLogger("bot")


def handlers():
    return [
        (shroud.build(), shroud_app.app_token(), "shroud"),
        (nemo.build(), nemo_app.app_token(), "nemo"),
    ]


def start(app, token, name):
    handler = SocketModeHandler(app, token)
    thread = threading.Thread(target=handler.start, name=name, daemon=True)
    thread.start()
    log.info("%s connected", name)
    return handler


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    load_dotenv(ENV_FILE)

    gone = missing("bot")
    if gone:
        print(f"bot: {len(gone)} required variable(s) missing: {', '.join(gone)}", file=sys.stderr)
        print("run `nemo doctor bot` for the whole picture", file=sys.stderr)
        return 78

    try:
        with session() as conn:
            refuse_if_seeded(conn)
    except SeededDeployment as refusal:
        print(f"bot: {refusal}", file=sys.stderr)
        shutdown()
        return 78

    running = [start(*one) for one in handlers()]
    stopping = threading.Event()

    def stop(*_):
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    log.info("bot: %d app(s) up, no handlers registered yet", len(running))
    stopping.wait()

    for handler in running:
        handler.close()
    shutdown()
    log.info("bot: stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
