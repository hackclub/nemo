import os
import time

PREFIX = "INGEST_TOKEN_"
USER_TOKEN_PREFIX = "xoxp-"


def discover(env=None):
    env = env if env is not None else os.environ
    found = []
    for name, value in env.items():
        if not name.startswith(PREFIX):
            continue
        index = name[len(PREFIX):]
        if not index.isdigit():
            continue
        token = (value or "").strip()
        if token:
            found.append((int(index), token))
    return sorted(found, key=lambda pair: pair[0])


def names(env=None):
    return [f"{PREFIX}{index}" for index, _ in discover(env)]


def problems(env=None):
    pool = discover(env)
    seen, trouble = {}, []
    for index, token in pool:
        if not token.startswith(USER_TOKEN_PREFIX):
            trouble.append(
                f"{PREFIX}{index} is not a user token, so it cannot read a public channel "
                "it has not joined"
            )
        first = seen.setdefault(token, index)
        if first != index:
            trouble.append(f"{PREFIX}{index} repeats {PREFIX}{first}, which shares one budget")
    return trouble


def describe(env=None):
    pool = discover(env)
    if not pool:
        return f"ingest pool: no {PREFIX}n set, thread replies stay on the proxy"
    listed = ", ".join(str(index) for index, _ in pool)
    line = f"ingest pool: {len(pool)} token(s), {PREFIX}[{listed}]"
    trouble = problems(env)
    if trouble:
        line += "".join(f"\ningest pool: {note}" for note in trouble)
    return line


def report(env=None):
    print(describe(env))
    return discover(env)


TIER3 = 50
DEFAULT_PER_MINUTE = float(os.environ.get("INGEST_SHARD_PER_MINUTE", TIER3))
BURST = 5.0
PARK_CEILING = 300.0


class Bucket:
    def __init__(self, per_minute, burst=BURST, clock=time.monotonic):
        self.per_minute = float(per_minute)
        self.burst = float(burst)
        self.tokens = float(burst)
        self.clock = clock
        self.filled_at = clock()

    def take(self):
        now = self.clock()
        rate = self.per_minute / 60.0
        self.tokens = min(self.burst, self.tokens + (now - self.filled_at) * rate)
        self.filled_at = now
        if self.tokens >= 1.0:
            self.tokens -= 1.0
            return True, 0.0
        return False, (1.0 - self.tokens) / rate


class Shard:
    def __init__(self, index, token, per_minute=None, clock=time.monotonic):
        self.index = index
        self.token = token
        self.per_minute = DEFAULT_PER_MINUTE if per_minute is None else float(per_minute)
        self.clock = clock
        self.buckets = {}
        self.parked_until = {}
        self.taken = 0
        self.throttles = 0

    def name(self):
        return f"{PREFIX}{self.index}"

    def parked_for(self, method=None):
        if method is not None:
            return max(0.0, self.parked_until.get(method, 0.0) - self.clock())
        held = [until - self.clock() for until in self.parked_until.values()]
        return max([0.0, *held])

    def bucket(self, method):
        if method not in self.buckets:
            self.buckets[method] = Bucket(self.per_minute, clock=self.clock)
        return self.buckets[method]

    def take(self, method):
        held = self.parked_for(method)
        if held > 0:
            return False, held
        ok, wait = self.bucket(method).take()
        if ok:
            self.taken += 1
        return ok, wait

    def park(self, method, seconds):
        self.throttles += 1
        seconds = min(max(float(seconds), 0.0), PARK_CEILING)
        self.parked_until[method] = self.clock() + seconds
        return seconds


class Pool:
    def __init__(self, env=None, per_minute=None, clock=time.monotonic):
        self.clock = clock
        self.shards = [
            Shard(index, token, per_minute=per_minute, clock=clock)
            for index, token in discover(env)
        ]
        self.cursor = 0

    def __len__(self):
        return len(self.shards)

    def per_minute(self):
        return sum(shard.per_minute for shard in self.shards)

    def acquire(self, method):
        if not self.shards:
            return None, 0.0
        waits = []
        for step in range(len(self.shards)):
            shard = self.shards[(self.cursor + step) % len(self.shards)]
            ok, wait = shard.take(method)
            if ok:
                self.cursor = (self.cursor + step + 1) % len(self.shards)
                return shard, 0.0
            waits.append(wait)
        return None, min(waits)

    def park(self, shard, method, seconds):
        return shard.park(method, seconds)

    def rates(self):
        return [
            (shard.name(), shard.taken, shard.throttles, round(shard.parked_for(), 1))
            for shard in self.shards
        ]
