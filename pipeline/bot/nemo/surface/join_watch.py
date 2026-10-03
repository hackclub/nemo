import logging

from bot.core import privileged, session
from bot.nemo import new_members, screening
from bot.nemo.surface import on_event

log = logging.getLogger("bot.nemo")


@on_event("team_join", open_to_all=True)
def arrived(ctx):
    user = new_members.whole((ctx.payload or {}).get("user"))
    if user is None:
        return None

    with session() as conn:
        fresh = new_members.arrived(conn, user)

    log.info("nemo: %s joined the workspace%s", user["id"], "" if fresh else ", already known")
    if not fresh:
        return user["id"]

    whole_user = privileged.profile(user["id"]) or user
    email = ((whole_user.get("profile") or {}).get("email"))
    with session() as conn:
        if whole_user is not user:
            new_members.keep(conn, whole_user)
        screening.screen(conn, user["id"], email, client=ctx.client)
    return user["id"]


@on_event("user_change", open_to_all=True)
def changed(ctx):
    user = new_members.whole((ctx.payload or {}).get("user"))
    if user is None:
        return None

    with session() as conn:
        new_members.keep(conn, user)
    return user["id"]
