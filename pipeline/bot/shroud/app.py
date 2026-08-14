import os

from slack_bolt import App


def build():
    return App(token=os.environ["SHROUD_BOT_TOKEN"], raise_error_for_unhandled_request=False)


def app_token():
    return os.environ["SHROUD_APP_TOKEN"]
