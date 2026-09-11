from lib import shards


def test_an_empty_environment_has_no_pool():
    assert shards.discover({}) == []
    assert shards.names({}) == []
    assert shards.problems({}) == []
    assert "no INGEST_TOKEN_n set" in shards.describe({})


def test_any_number_of_tokens_is_read_in_index_order():
    env = {
        "INGEST_TOKEN_10": "xoxp-ten",
        "INGEST_TOKEN_2": "xoxp-two",
        "INGEST_TOKEN_1": "xoxp-one",
        "PGHOST": "irrelevant",
    }
    assert shards.discover(env) == [(1, "xoxp-one"), (2, "xoxp-two"), (10, "xoxp-ten")]
    assert shards.names(env) == ["INGEST_TOKEN_1", "INGEST_TOKEN_2", "INGEST_TOKEN_10"]


def test_gaps_and_blanks_and_non_numeric_suffixes_are_skipped():
    env = {
        "INGEST_TOKEN_1": "xoxp-one",
        "INGEST_TOKEN_3": "  ",
        "INGEST_TOKEN_7": "xoxp-seven",
        "INGEST_TOKEN_": "xoxp-nameless",
        "INGEST_TOKEN_TWO": "xoxp-worded",
    }
    assert shards.discover(env) == [(1, "xoxp-one"), (7, "xoxp-seven")]


def test_describe_counts_the_pool_without_printing_a_token():
    env = {"INGEST_TOKEN_1": "xoxp-secret-one", "INGEST_TOKEN_2": "xoxp-secret-two"}
    line = shards.describe(env)
    assert "2 token(s)" in line
    assert "INGEST_TOKEN_[1, 2]" in line
    assert "secret" not in line


def test_a_bot_token_in_the_pool_is_called_out():
    env = {"INGEST_TOKEN_1": "xoxb-a-bot-token"}
    trouble = shards.problems(env)
    assert len(trouble) == 1
    assert "not a user token" in trouble[0]
    assert "not a user token" in shards.describe(env)


def test_a_repeated_token_is_called_out_because_it_shares_one_budget():
    env = {"INGEST_TOKEN_1": "xoxp-same", "INGEST_TOKEN_2": "xoxp-same"}
    trouble = shards.problems(env)
    assert any("repeats INGEST_TOKEN_1" in note for note in trouble)


def test_a_healthy_pool_reports_no_trouble():
    env = {"INGEST_TOKEN_1": "xoxp-one", "INGEST_TOKEN_2": "xoxp-two"}
    assert shards.problems(env) == []
    assert "\n" not in shards.describe(env)


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def pool_of(n, per_minute=50.0, clock=None):
    clock = clock or Clock()
    env = {f"INGEST_TOKEN_{i}": f"xoxp-{i}" for i in range(1, n + 1)}
    return shards.Pool(env=env, per_minute=per_minute, clock=clock), clock


def allowed_in(seconds, n, per_minute=50.0):
    pool, clock = pool_of(n, per_minute)
    granted = 0
    while clock.t < seconds:
        shard, wait = pool.acquire("conversations.replies")
        if shard:
            granted += 1
        else:
            clock.advance(max(wait, 0.01))
    return granted


def test_the_pool_ceiling_is_the_sum_of_its_shards():
    pool, _ = pool_of(4, per_minute=50.0)
    assert len(pool) == 4
    assert pool.per_minute() == 200.0


def test_n_shards_allow_n_times_the_requests():
    one = allowed_in(60.0, 1)
    assert one == allowed_in(60.0, 1)
    for n in (2, 3, 5):
        assert allowed_in(60.0, n) == one * n


def test_an_empty_pool_acquires_nothing_without_waiting():
    pool = shards.Pool(env={})
    assert pool.acquire("conversations.replies") == (None, 0.0)


def test_a_parked_shard_is_skipped_and_the_next_one_serves():
    pool, _ = pool_of(2)
    first, _ = pool.acquire("m")
    pool.park(first, "m", 30)
    for _ in range(3):
        served, wait = pool.acquire("m")
        assert served is not first
        assert wait == 0.0


def test_when_every_shard_is_parked_the_wait_is_the_shortest_remaining():
    pool, clock = pool_of(2)
    a, b = pool.shards
    pool.park(a, "m", 45)
    pool.park(b, "m", 12)
    served, wait = pool.acquire("m")
    assert served is None
    assert wait == 12.0
    clock.advance(12.1)
    served, _ = pool.acquire("m")
    assert served is b


def test_parking_is_per_method_because_slack_counts_per_method():
    pool, _ = pool_of(1)
    shard, _ = pool.acquire("conversations.replies")
    pool.park(shard, "conversations.replies", 60)
    served, wait = pool.acquire("conversations.history")
    assert served is shard
    assert wait == 0.0
    blocked, held = pool.acquire("conversations.replies")
    assert blocked is None
    assert held == 60.0


def test_round_robin_spreads_the_work_evenly():
    pool, clock = pool_of(5)
    for _ in range(300):
        shard, wait = pool.acquire("m")
        if not shard:
            clock.advance(wait)
    taken = [count for _, count, _, _ in pool.rates()]
    assert max(taken) - min(taken) <= 1


def test_a_park_is_capped_so_a_bad_retry_after_cannot_stall_a_shard_forever():
    pool, _ = pool_of(1)
    shard = pool.shards[0]
    assert pool.park(shard, "m", 10_000) == shards.PARK_CEILING
    assert pool.park(shard, "m", -5) == 0.0


def test_rates_report_counts_and_never_a_token():
    pool, _ = pool_of(2)
    pool.acquire("m")
    line = str(pool.rates())
    assert "INGEST_TOKEN_1" in line
    assert "xoxp" not in line
