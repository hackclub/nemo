import logging
import os
import threading
import time

logger = logging.getLogger("uvicorn.error")

MODE = os.environ.get("PROXY_BUDGET", "on").strip().lower()

TIER2, TIER3, TIER4 = 20, 50, 100

BURST = 5
HEAL_SECONDS = 60
HEAL_STEP = 20
BACKOFF_COOLDOWN = 10
BACKOFF_FACTOR = 0.75
FLOOR_BOOST = 40
PAUSE_CEILING = 1.0
PAUSE_TRIES = 3

LIMITS = {
    ("pipeline", "admin", "conversations.replies"): (TIER3, 120),
    ("pipeline", "admin", "conversations.history"): (TIER3, 120),
    ("pipeline", "admin", "conversations.info"): (TIER3, 120),
    ("pipeline", "admin", "search.messages"): (TIER2, 80),
    ("pipeline", "admin"): (TIER4, 500),
    ("pipeline", "internal"): (TIER3, 100),
    ("web", "internal"): (TIER2, 40),
}


class Bucket:
    def __init__(self, tier, boost, burst=BURST):
        self.tier = float(tier)
        self.boost = float(boost)
        self.ceiling = float(boost)
        self.burst = float(burst)
        self.tokens = float(burst)
        self.filled_at = time.monotonic()
        self.healed_at = self.filled_at
        self.backed_off_at = 0.0
        self.throttles = 0
        self.lock = threading.Lock()

    @property
    def per_minute(self):
        return self.tier + self.boost

    def take(self):
        with self.lock:
            now = time.monotonic()
            if self.boost < self.ceiling and now - self.healed_at >= HEAL_SECONDS:
                self.boost = min(self.ceiling, self.boost + HEAL_STEP)
                self.healed_at = now
            rate = self.per_minute / 60.0
            self.tokens = min(self.burst, self.tokens + (now - self.filled_at) * rate)
            self.filled_at = now
            if self.tokens >= 1.0:
                self.tokens -= 1.0
                return True, 0.0
            return False, (1.0 - self.tokens) / rate

    def back_off(self):
        with self.lock:
            self.throttles += 1
            now = time.monotonic()
            if now - self.backed_off_at < BACKOFF_COOLDOWN:
                return None
            self.boost = max(FLOOR_BOOST, self.boost * BACKOFF_FACTOR)
            self.backed_off_at = now
            self.healed_at = now
            return self.per_minute


_buckets = {key: Bucket(tier, boost) for key, (tier, boost) in LIMITS.items()}
_refused = {}
_paused = {}


def keys_for(client, credential, method):
    for key in ((client, credential, method), (client, credential)):
        if key in _buckets:
            return [key]
    return []


def take(client, credential, method):
    keys = keys_for(client, credential, method)
    if not keys:
        return None
    key = keys[0]
    bucket = _buckets[key]
    wait = 0.0
    for _ in range(PAUSE_TRIES):
        ok, wait = bucket.take()
        if ok:
            return None
        if wait > PAUSE_CEILING or MODE != "on":
            break
        _paused[key] = _paused.get(key, 0) + 1
        time.sleep(wait)
    _refused[key] = _refused.get(key, 0) + 1
    label = ":".join(key)
    if MODE == "on":
        return max(1, int(wait + 0.999)), label
    if MODE == "observe":
        logger.warning("budget would refuse %s for %s (%d so far), retry in %.1fs", method, label, _refused[key], wait)
    return None


def back_off(client, credential, method):
    key = (client, credential, method)
    bucket = _buckets.get(key)
    if bucket is None:
        return None
    now = bucket.back_off()
    if now is not None:
        logger.warning("upstream throttled %s, boost halved, now pacing at %.0f/min", method, now)
    return now


def rates():
    return {
        ":".join(key): round(bucket.per_minute)
        for key, bucket in _buckets.items()
        if len(key) == 3
    }


def report():
    return {
        "mode": MODE,
        "tuning": {
            "burst": BURST,
            "floor_boost": FLOOR_BOOST,
            "backoff_factor": BACKOFF_FACTOR,
            "backoff_cooldown": BACKOFF_COOLDOWN,
            "heal_step": HEAL_STEP,
            "heal_seconds": HEAL_SECONDS,
            "pause_ceiling": PAUSE_CEILING,
        },
        "methods": {
            ":".join(key): {
                "per_minute": round(bucket.per_minute, 1),
                "tier": int(bucket.tier),
                "boost": round(bucket.boost, 1),
                "ceiling": int(bucket.ceiling),
                "burst": int(bucket.burst),
                "paused": _paused.get(key, 0),
                "refused": _refused.get(key, 0),
                "upstream_429": bucket.throttles,
            }
            for key, bucket in _buckets.items()
        },
    }
