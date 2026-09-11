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
