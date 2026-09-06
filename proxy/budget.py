import logging
import os
import threading
import time

logger = logging.getLogger("uvicorn.error")

MODE = os.environ.get("PROXY_BUDGET", "on").strip().lower()

PER_MINUTE = {
    ("pipeline", "internal"): 150,
    ("pipeline", "admin"): 240,
    ("pipeline", "admin", "search.messages"): 100,
    ("web", "internal"): 60,
}


class Bucket:
    def __init__(self, per_minute):
        self.capacity = float(per_minute)
        self.tokens = float(per_minute)
        self.rate = per_minute / 60.0
        self.filled_at = time.monotonic()
        self.lock = threading.Lock()

    def take(self):
        with self.lock:
            now = time.monotonic()
            self.tokens = min(self.capacity, self.tokens + (now - self.filled_at) * self.rate)
            self.filled_at = now
            if self.tokens >= 1.0:
                self.tokens -= 1.0
                return True, 0.0
            return False, (1.0 - self.tokens) / self.rate


_buckets = {key: Bucket(rate) for key, rate in PER_MINUTE.items()}
_refused = {}


def keys_for(client, credential, method):
    keys = [(client, credential, method), (client, credential)]
    return [key for key in keys if key in _buckets]


def take(client, credential, method):
    waits = []
    for key in keys_for(client, credential, method):
        ok, wait = _buckets[key].take()
        if not ok:
            waits.append((key, wait))
    if not waits:
        return None
    key, wait = max(waits, key=lambda pair: pair[1])
    _refused[key] = _refused.get(key, 0) + 1
    label = ":".join(key)
    if MODE == "on":
        return max(1, int(wait + 0.999)), label
    if MODE == "observe":
        logger.warning("budget would refuse %s for %s (%d so far), retry in %.1fs", method, label, _refused[key], wait)
    return None


def report():
    return {
        "mode": MODE,
        "limits_per_minute": {":".join(key): int(bucket.capacity) for key, bucket in _buckets.items()},
        "refused": {":".join(key): count for key, count in _refused.items()},
    }
