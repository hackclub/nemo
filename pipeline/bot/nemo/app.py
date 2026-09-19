import os

from slack_bolt import App

from bot.nemo import channel, command


def build(on_reply=None):
    app = App(token=os.environ["NEMO_BOT_TOKEN"], raise_error_for_unhandled_request=False)
    channel.register(app, on_reply)
    command.register(app)
    return app


def app_token():
    return os.environ["NEMO_APP_TOKEN"]


def firehouse_channel():
    return channel.firehouse_channel()
