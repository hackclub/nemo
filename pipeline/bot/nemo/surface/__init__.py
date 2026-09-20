import logging

from bot.core import access, audit, session

log = logging.getLogger("bot.nemo")

SHORTCUT = "shortcut"
ACTION = "action"
VIEW = "view"
EVENT = "event"
COMMAND = "command"

ENTRIES = []


class Undeclared(RuntimeError):
    """A Slack surface that writes without naming the capability it needs"""


class Entry:
    def __init__(self, kind, key, needs, fn, refuse_block=None, open_to_all=False, tag=None):
        self.kind = kind
        self.key = key
        self.needs = needs
        self.fn = fn
        self.refuse_block = refuse_block
        self.open_to_all = open_to_all
        self.tag = tag

    def __repr__(self):
        return f"<{self.kind} {self.key} needs={self.needs}>"


def bind(kind, key, fn, tag=None):
    name = tag or getattr(fn, "__qualname__", repr(fn))
    ENTRIES[:] = [one for one in ENTRIES if one.tag != name]
    ENTRIES.append(Entry(kind, key, None, fn, open_to_all=True, tag=name))


def keep(kind, key, needs, refuse_block=None, open_to_all=False):
    def hold(fn):
        ENTRIES.append(Entry(kind, key, needs, fn, refuse_block, open_to_all))
        return fn

    return hold


def on_shortcut(key, *, needs=None, open_to_all=False):
    return keep(SHORTCUT, key, needs, open_to_all=open_to_all)


def on_action(key, *, needs=None, open_to_all=False):
    return keep(ACTION, key, needs, open_to_all=open_to_all)


def on_view(key, *, needs=None, refuse_block=None, open_to_all=False):
    return keep(VIEW, key, needs, refuse_block, open_to_all)


def on_event(key, *, needs=None, open_to_all=False):
    return keep(EVENT, key, needs, open_to_all=open_to_all)


def on_command(key, *, needs=None, open_to_all=False):
    return keep(COMMAND, key, needs, open_to_all=open_to_all)


class Ctx:
    def __init__(self, entry, body, client, ack, payload=None):
        self.entry = entry
        self.body = body or {}
        self.client = client
        self.ack = ack
        self.payload = payload if payload is not None else self.body

    @property
    def user_id(self):
        said = self.body.get("user")
        if isinstance(said, dict):
            return said.get("id")
        return said or self.payload.get("user")

    @property
    def channel_id(self):
        said = self.body.get("channel")
        if isinstance(said, dict):
            return said.get("id")
        return said or self.payload.get("channel")

    @property
    def message_ts(self):
        return (self.body.get("message") or {}).get("ts") or self.payload.get("ts")

    @property
    def thread_ts(self):
        message = self.body.get("message") or {}
        return message.get("thread_ts") or message.get("ts") or self.payload.get("thread_ts")

    @property
    def trigger_id(self):
        return self.body.get("trigger_id")

    @property
    def view(self):
        return self.body.get("view") or {}

    def acknowledge(self):
        if self.entry.kind != VIEW and callable(self.ack):
            self.ack()

    def join(self, channel_id=None):
        try:
            self.client.conversations_join(channel=channel_id or self.channel_id)
        except Exception as failure:
            log.info("nemo: could not join %s: %s", channel_id or self.channel_id, failure)

    def whisper(self, said, channel_id=None, thread_ts=None):
        room = channel_id or self.channel_id
        if not room:
            log.info("nemo: nowhere to say %r", said)
            return
        try:
            self.client.chat_postEphemeral(
                channel=room, user=self.user_id,
                thread_ts=thread_ts or self.thread_ts, text=said,
            )
        except Exception as failure:
            log.warning("nemo: could not whisper: %s", failure)


def refused(entry, ctx, why):
    with session() as conn:
        audit.record(
            conn, "permission", 0, "refused", ctx.user_id,
            after={"permission": entry.needs, "surface": f"{entry.kind}:{entry.key}"},
        )
    if entry.kind == VIEW and entry.refuse_block:
        ctx.ack(response_action="errors", errors={entry.refuse_block: why})
        return
    ctx.acknowledge()
    ctx.whisper(why)


def allowed(entry, ctx):
    if entry.open_to_all:
        return True, None
    with session() as conn:
        return access.may(conn, ctx.user_id, entry.needs)


INJECTED = ("ack", "body", "client", "payload")


def guarded(entry):
    def run(ack=None, body=None, client=None, payload=None):
        ctx = Ctx(entry, body, client, ack, payload)
        may, why = allowed(entry, ctx)
        if not may:
            return refused(entry, ctx, why)
        ctx.acknowledge()
        return entry.fn(ctx)

    return run


def declared():
    missing = [one for one in ENTRIES if not one.open_to_all and not one.needs]
    if missing:
        raise Undeclared(
            "these Slack surfaces write without declaring a capability: "
            + ", ".join(f"{one.kind}:{one.key}" for one in missing)
        )
    return ENTRIES


def fanned(entries):
    runners = [(one, guarded(one)) for one in entries]

    def run(ack=None, body=None, client=None, payload=None):
        held = {"ack": ack, "body": body, "client": client, "payload": payload}
        for entry, runner in runners:
            try:
                runner(**held)
            except Exception:
                log.exception("nemo: %s:%s failed", entry.kind, entry.key)

    return run


def register(app):
    hooks = {
        SHORTCUT: app.shortcut,
        ACTION: app.action,
        VIEW: app.view,
        EVENT: app.event,
        COMMAND: app.command,
    }
    grouped = {}
    for entry in declared():
        grouped.setdefault((entry.kind, entry.key), []).append(entry)

    for (kind, key), entries in grouped.items():
        hooks[kind](key)(fanned(entries))

    log.info("nemo: %d Slack surface(s) on %d listener(s)", len(ENTRIES), len(grouped))
    return ENTRIES
