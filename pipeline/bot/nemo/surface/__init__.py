import logging

from slack_sdk.webhook import WebhookClient

from bot.core import access, audit, session
from bot.nemo import channels

log = logging.getLogger("bot.nemo")

SHORTCUT = "shortcut"
ACTION = "action"
VIEW = "view"
EVENT = "event"
COMMAND = "command"

ENTRIES = []


class UndeclaredCapabilityError(RuntimeError):
    """Raised when a Slack surface writes without declaring the capability it needs."""


class SurfaceEntry:
    def __init__(self, kind, key, needs, fn, refuse_block=None, open_to_all=False, tag=None,
                 silent_refusal=False):
        self.kind = kind
        self.key = key
        self.needs = needs
        self.fn = fn
        self.refuse_block = refuse_block
        self.open_to_all = open_to_all
        self.tag = tag
        self.silent_refusal = silent_refusal

    def __repr__(self):
        return f"<{self.kind} {self.key} needs={self.needs}>"


def bind(kind, key, fn, tag=None):
    name = tag or getattr(fn, "__qualname__", repr(fn))
    ENTRIES[:] = [one for one in ENTRIES if one.tag != name]
    ENTRIES.append(SurfaceEntry(kind, key, None, fn, open_to_all=True, tag=name))


def register_entry(kind, key, needs, refuse_block=None, open_to_all=False, silent_refusal=False):
    def decorator(fn):
        ENTRIES.append(SurfaceEntry(kind, key, needs, fn, refuse_block, open_to_all,
                                    silent_refusal=silent_refusal))
        return fn

    return decorator


def on_shortcut(key, *, needs=None, open_to_all=False):
    return register_entry(SHORTCUT, key, needs, open_to_all=open_to_all)


def on_action(key, *, needs=None, open_to_all=False, silent_refusal=False):
    return register_entry(ACTION, key, needs, open_to_all=open_to_all, silent_refusal=silent_refusal)


def on_view(key, *, needs=None, refuse_block=None, open_to_all=False):
    return register_entry(VIEW, key, needs, refuse_block, open_to_all)


def on_event(key, *, needs=None, open_to_all=False):
    return register_entry(EVENT, key, needs, open_to_all=open_to_all)


def on_command(key, *, needs=None, open_to_all=False):
    return register_entry(COMMAND, key, needs, open_to_all=open_to_all)


class Ctx:
    def __init__(self, entry, body, client, ack, payload=None):
        self.entry = entry
        self.body = body or {}
        self.client = client
        self.ack = ack
        self.payload = payload if payload is not None else self.body

    @property
    def user_id(self):
        user = self.body.get("user")
        if isinstance(user, dict):
            return user.get("id")
        return user or self.payload.get("user")

    @property
    def channel_id(self):
        channel = self.body.get("channel")
        if isinstance(channel, dict):
            return channel.get("id")
        return channel or self.payload.get("channel")

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

    ALREADY_IN = ("method_not_supported_for_channel_type", "already_in_channel")

    def join(self, channel_id=None):
        where = channel_id or self.channel_id
        try:
            self.client.conversations_join(channel=where)
        except Exception as failure:
            if any(one in str(failure) for one in self.ALREADY_IN):
                return
            log.info("nemo: could not join %s: %s", where, failure)

    @property
    def response_url(self):
        return self.body.get("response_url")

    def join_public(self, channel_id):
        if not channel_id or channel_id[:1] != "C":
            return
        try:
            with session() as conn:
                channels.join_public(self.client, conn, channel_id, by=self.user_id)
        except Exception as failure:
            log.info("nemo: could not join %s before answering: %s", channel_id, failure)

    def send_to_response_url(self, message, thread_ts=None):
        payload = {"text": message, "response_type": "ephemeral"}
        if thread_ts:
            payload["thread_ts"] = thread_ts
        try:
            sent = WebhookClient(self.response_url).send(**payload)
        except Exception as failure:
            log.info("nemo: the response url refused %r: %s", message, failure)
            return False
        return sent.status_code == 200

    def respond_in_place(self, message, channel_id, thread_ts=None):
        if not self.response_url or channel_id != self.channel_id:
            return False
        if thread_ts and self.send_to_response_url(message, thread_ts):
            return True
        return self.send_to_response_url(message)

    def post_ephemeral(self, message, channel_id=None, thread_ts=None):
        target_channel_id = channel_id or self.channel_id
        if not target_channel_id:
            log.info("nemo: nowhere to say %r", message)
            return False

        target_thread_ts = thread_ts or self.thread_ts
        self.join_public(target_channel_id)
        try:
            self.client.chat_postEphemeral(
                channel=target_channel_id, user=self.user_id,
                thread_ts=target_thread_ts, text=message,
            )
            return True
        except Exception as failure:
            reason = channels.slack_error_code(failure)

        if self.respond_in_place(message, target_channel_id, target_thread_ts):
            return True
        log.warning("nemo: %s %s could not say %r in %s: %s",
                    getattr(self.entry, "kind", "surface"), getattr(self.entry, "key", ""),
                    message, target_channel_id, reason)
        return False


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
    if entry.silent_refusal:
        return
    ctx.post_ephemeral(why)


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
        raise UndeclaredCapabilityError(
            "these Slack surfaces write without declaring a capability: "
            + ", ".join(f"{one.kind}:{one.key}" for one in missing)
        )
    return ENTRIES


def run_entries(entries):
    runners = [(one, guarded(one)) for one in entries]

    def run(ack=None, body=None, client=None, payload=None):
        handler_kwargs = {"ack": ack, "body": body, "client": client, "payload": payload}
        for entry, runner in runners:
            try:
                runner(**handler_kwargs)
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
        hooks[kind](key)(run_entries(entries))

    log.info("nemo: %d Slack surface(s) on %d listener(s)", len(ENTRIES), len(grouped))
    return ENTRIES
