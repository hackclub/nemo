import os

from slack_bolt import App
from slack_sdk import WebClient

from bot.nemo import channel, command, handlers, surface
from lib.slack_client import RETRY_HANDLERS
from bot.nemo.surface import (
    bot_watch,  # noqa: F401
    channel_watch,  # noqa: F401
    reaction_watch,  # noqa: F401
    thread_destroy,  # noqa: F401
    thread_lock,  # noqa: F401
    thread_watch,  # noqa: F401
)


def build(on_reply=None):
    client = WebClient(token=os.environ["NEMO_BOT_TOKEN"], retry_handlers=RETRY_HANDLERS)
    app = App(client=client, raise_error_for_unhandled_request=False)
    handlers.register(app, on_reply)
    command.register(app)
    surface.register(app)
    return app


def app_token():
    return os.environ["NEMO_APP_TOKEN"]


def firehouse_channel():
    return channel.firehouse_channel()
