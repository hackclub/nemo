from bot.nemo.enforcement import (
    account_age, channel_ban, deactivate, purge, readonly, shush, slowmode,
)

ENFORCEMENTS = {shush.KIND: shush, channel_ban.KIND: channel_ban,
                deactivate.KIND: deactivate}

CHANNEL_ENFORCEMENTS = (readonly, slowmode, account_age)

__all__ = ["CHANNEL_ENFORCEMENTS", "ENFORCEMENTS", "account_age", "channel_ban", "deactivate",
           "purge", "readonly", "shush", "slowmode"]


def take_up(client, conn, guard):
    enforcement = ENFORCEMENTS.get(guard["kind"])
    if enforcement is None:
        return False
    return enforcement.take_up(client, conn, guard)
