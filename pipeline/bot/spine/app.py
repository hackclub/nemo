import os

from slack_bolt import App

from bot.spine import events


def build():
    app = App(token=os.environ["SLACK_BOT_TOKEN"], raise_error_for_unhandled_request=False)
    events.register(app)
    return app


def app_token():
    return os.environ["SLACK_APP_TOKEN"]
