import os

from slack_bolt import App

from bot.nemo import channel, command, handlers, surface
from bot.nemo.surface import (
    thread_destroy,  # noqa: F401
    thread_lock,  # noqa: F401
    thread_watch,  # noqa: F401
)


def build(on_reply=None):
    app = App(token=os.environ["NEMO_BOT_TOKEN"], raise_error_for_unhandled_request=False)
    handlers.register(app, on_reply)
    command.register(app)
    surface.register(app)
    return app


def app_token():
    return os.environ["NEMO_APP_TOKEN"]


def firehouse_channel():
    return channel.firehouse_channel()
