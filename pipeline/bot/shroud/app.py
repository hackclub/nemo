import os

from slack_bolt import App

from bot.shroud import dm


def build():
    app = App(token=os.environ["SHROUD_BOT_TOKEN"], raise_error_for_unhandled_request=False)
    dm.register(app)
    return app


def app_token():
    return os.environ["SHROUD_APP_TOKEN"]
