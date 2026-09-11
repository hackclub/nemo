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


def fake_pool(n, per_minute=600.0, throttle_first=()):
    clock = Clock()
    env = {f"INGEST_TOKEN_{i}": f"xoxp-{i}" for i in range(1, n + 1)}
    pool = shards.Pool(env=env, per_minute=per_minute, clock=clock)
    seen = []
    for shard in pool.shards:
        def invoke(method, params, timeout=None, _s=shard):
            seen.append(_s.name())
            if _s.name() in throttle_first and seen.count(_s.name()) == 1:
                raise shards.Throttled(5)
            cursor = params.get("cursor")
            page = 0 if not cursor else int(cursor)
            nxt = str(page + 1) if page + 1 < 3 else ""
            return {
                "messages": [{"ts": f"{page}.{i}"} for i in range(2)],
                "response_metadata": {"next_cursor": nxt},
            }
        shard.invoke = invoke
    return pool, clock, seen


def walk(client):
    return list(client.paginate(
        "conversations.replies", {"channel": "C1", "ts": "1"}, "messages",
        page_size=200, cursor_param="cursor", page_param="limit",
        cursor_field="response_metadata.next_cursor", credential="admin",
    ))


def test_the_sharded_client_inherits_pagination_and_walks_every_page():
    pool, clock, seen = fake_pool(2)
    client = shards.ShardedClient(pool=pool, sleep=clock.advance)
    assert len(walk(client)) == 6
    assert len(seen) == 3


def test_pages_of_one_walk_spread_across_shards():
    pool, clock, seen = fake_pool(2)
    client = shards.ShardedClient(pool=pool, sleep=clock.advance)
    walk(client)
    assert seen == ["INGEST_TOKEN_1", "INGEST_TOKEN_2", "INGEST_TOKEN_1"]


def test_a_throttle_parks_that_shard_and_another_finishes_the_walk():
    pool, clock, seen = fake_pool(2, throttle_first=("INGEST_TOKEN_1",))
    client = shards.ShardedClient(pool=pool, sleep=clock.advance)
    assert len(walk(client)) == 6
    first, second = pool.shards
    assert first.throttles == 1
    assert first.parked_for("conversations.replies") == 5.0
    assert second.taken == 3


def test_a_lone_throttled_shard_waits_and_then_recovers():
    pool, clock, seen = fake_pool(1, throttle_first=("INGEST_TOKEN_1",))
    client = shards.ShardedClient(pool=pool, sleep=clock.advance)
    assert len(walk(client)) == 6
    assert pool.shards[0].throttles == 1


def test_num_found_still_reaches_the_walk_guard():
    pool, clock, _ = fake_pool(1)
    pool.shards[0].invoke = lambda m, p, timeout=None: {
        "messages": [{"ts": "1"}], "num_found": 4242,
        "response_metadata": {"next_cursor": ""},
    }
    client = shards.ShardedClient(pool=pool, sleep=clock.advance)
    list(client.paginate("conversations.replies", {"channel": "C1"}, "messages",
                         cursor_field="response_metadata.next_cursor"))
    assert client.last_num_found == 4242


def test_an_empty_pool_refuses_to_build_a_client():
    import pytest

    with pytest.raises(shards.NoPool):
        shards.ShardedClient(pool=shards.Pool(env={}))


def test_the_pool_summary_reads_as_a_heartbeat_note():
    pool, _ = pool_of(2)
    pool.acquire("m")
    pool.acquire("m")
    pool.park(pool.shards[0], "m", 7)
    line = pool.summary()
    assert line.startswith("2 shard(s): ")
    assert "s1" in line and "s2" in line
    assert "1t" in line
    assert "xoxp" not in line
    assert shards.Pool(env={}).summary() == "no pool"


def test_the_shard_check_reads_a_survey_without_calling_slack():
    from checks import shards as check

    found = [
        (1, ({"ok": True, "team_id": "T1", "user_id": "U1"}, None)),
        (2, ({"ok": True, "team_id": "T1", "user_id": "U1"}, None)),
    ]
    assert check.the_pool_is_configured(None, found)[1] == "pass"
    assert check.every_token_is_live(None, found)[1] == "pass"
    assert check.every_token_is_a_user_token(None, found)[1] == "pass"
    assert check.every_token_points_at_one_workspace(None, found)[1] == "pass"


def test_the_shard_check_catches_a_dead_a_bot_and_a_foreign_token():
    from checks import shards as check

    dead = [(1, (None, "invalid_auth"))]
    assert check.every_token_is_live(None, dead)[1] == "fail"
    assert "invalid_auth" in check.every_token_is_live(None, dead)[2]

    bot = [(1, ({"ok": True, "team_id": "T1", "bot_id": "B1"}, None))]
    assert check.every_token_is_a_user_token(None, bot)[1] == "fail"

    foreign = [
        (1, ({"ok": True, "team_id": "T1"}, None)),
        (2, ({"ok": True, "team_id": "T2"}, None)),
    ]
    assert check.every_token_points_at_one_workspace(None, foreign)[1] == "fail"


def test_an_unconfigured_pool_warns_rather_than_failing():
    from checks import shards as check

    assertion, status, observed, _ = check.the_pool_is_configured(None, [])
    assert status == "warn"
    assert "stay on the proxy" in observed
    assert check.severity_of(assertion, status) == "warn"


def test_the_bucket_never_over_issues_under_concurrent_fetchers():
    import threading
    import time as clocklib

    def yielding_clock():
        clocklib.sleep(0)
        return 0.0

    bucket = shards.Bucket(per_minute=6000.0, burst=50.0, clock=yielding_clock)
    granted = []
    barrier = threading.Barrier(20)

    def grab():
        barrier.wait()
        for _ in range(20):
            ok, _ = bucket.take()
            if ok:
                granted.append(1)

    threads = [threading.Thread(target=grab) for _ in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(granted) == 50


def test_the_pool_hands_every_fetcher_a_distinct_turn():
    import threading
    from collections import Counter

    pool, _ = pool_of(5, per_minute=60000.0)
    seen = []
    guard = threading.Lock()
    barrier = threading.Barrier(20)

    def grab():
        barrier.wait()
        for _ in range(50):
            shard, _ = pool.acquire("m")
            if shard:
                with guard:
                    seen.append(shard.name())

    threads = [threading.Thread(target=grab) for _ in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    spread = Counter(seen)
    assert len(spread) == 5
    assert max(spread.values()) - min(spread.values()) <= len(seen) // 10
    assert sum(spread.values()) == sum(s.taken for s in pool.shards)


def test_parking_and_counting_survive_concurrent_throttles():
    import threading

    pool, _ = pool_of(3, per_minute=60000.0)
    barrier = threading.Barrier(15)

    def churn():
        barrier.wait()
        for _ in range(30):
            shard, _ = pool.acquire("m")
            if shard:
                pool.park(shard, "m", 0)

    threads = [threading.Thread(target=churn) for _ in range(15)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sum(s.throttles for s in pool.shards) == sum(s.taken for s in pool.shards)
