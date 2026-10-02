import time


class Deadline:
    def __init__(self, seconds):
        self.seconds = float(seconds)
        self.at = time.monotonic() + self.seconds

    def remaining(self):
        return max(0.0, self.at - time.monotonic())

    def expired(self):
        return self.remaining() <= 0.0

    def clamp(self, wait):
        return max(0.0, min(float(wait), self.remaining()))

    def __repr__(self):
        return f"Deadline({self.seconds:.0f}s, {self.remaining():.1f}s left)"
