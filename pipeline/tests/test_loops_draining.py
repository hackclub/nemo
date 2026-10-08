import threading

from bot.core import loops


class Counter:
    def __init__(self, answers=()):
        self.answers = list(answers)
        self.ran = 0
        self.tick = threading.Semaphore(0)

    def __call__(self):
        self.ran += 1
        self.tick.release()
        return self.answers.pop(0) if self.answers else False


def started(work, stopping, settle=0.05):
    return loops.draining("test", work, stopping, settle=settle, every=30)


def test_it_drains_once_on_start():
    stopping, work = threading.Event(), Counter()
    wake = started(work, stopping)

    assert work.tick.acquire(timeout=1)
    assert not work.tick.acquire(timeout=0.2)
    stopping.set()
    wake()


def test_wakes_that_arrive_together_drain_once():
    stopping, work = threading.Event(), Counter()
    wake = started(work, stopping)
    assert work.tick.acquire(timeout=1)

    for _ in range(5):
        wake()

    assert work.tick.acquire(timeout=1)
    assert not work.tick.acquire(timeout=0.3)
    assert work.ran == 2
    stopping.set()
    wake()


def test_it_goes_again_without_a_wake_while_work_says_there_is_more():
    stopping, work = threading.Event(), Counter(answers=[True, True, False])
    wake = started(work, stopping)

    for _ in range(3):
        assert work.tick.acquire(timeout=1)
    assert not work.tick.acquire(timeout=0.2)
    stopping.set()
    wake()


def test_a_failing_drain_does_not_stop_the_loop():
    stopping = threading.Event()
    tick = threading.Semaphore(0)
    calls = []

    def work():
        calls.append(1)
        tick.release()
        if len(calls) == 1:
            raise RuntimeError("database went away")
        return False

    wake = started(work, stopping)
    assert tick.acquire(timeout=1)
    wake()
    assert tick.acquire(timeout=1)
    stopping.set()
    wake()


def test_stopping_during_the_settle_ends_the_loop():
    stopping, work = threading.Event(), Counter()
    wake = started(work, stopping, settle=0.2)
    assert work.tick.acquire(timeout=1)

    wake()
    stopping.set()

    assert not work.tick.acquire(timeout=0.4)
