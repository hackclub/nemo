import os
from concurrent.futures import ThreadPoolExecutor

from slack_bolt import App
from slack_sdk import WebClient

from bot.nemo import channel, command, handlers, surface
from bot.nemo.enforcement import (  # noqa: F401
    account_age,
    channel_ban,
    readonly,
    shush,
    slowmode,
)
from lib.slack_client import RETRY_HANDLERS
from bot.nemo.surface import (
    automod_watch,  # noqa: F401
    autoresponse,  # noqa: F401
    bot_watch,  # noqa: F401
    channel_watch,  # noqa: F401
    join_watch,  # noqa: F401
    message_activity,  # noqa: F401
    reaction_watch,  # noqa: F401
    thread_destroy,  # noqa: F401
    thread_lock,  # noqa: F401
    thread_watch,  # noqa: F401
    unsub_shield,  # noqa: F401
)

LISTENER_THREADS = 16


def build(on_reply=None):
    client = WebClient(token=os.environ["NEMO_BOT_TOKEN"], retry_handlers=RETRY_HANDLERS)
    app = App(
        client=client,
        raise_error_for_unhandled_request=False,
        listener_executor=ThreadPoolExecutor(
            max_workers=LISTENER_THREADS, thread_name_prefix="nemo-listener"),
    )
    handlers.register(app, on_reply)
    command.register(app)
    surface.register(app)
    return app


def app_token():
    return os.environ["NEMO_APP_TOKEN"]


def internal_log_channel():
    return channel.internal_log_channel()
