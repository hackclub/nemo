import os

from slack_bolt import App


def build():
    return App(token=os.environ["NEMO_BOT_TOKEN"], raise_error_for_unhandled_request=False)


def app_token():
    return os.environ["NEMO_APP_TOKEN"]


def firehouse_channel():
    return os.environ["FIREHOUSE_CHANNEL_ID"]
