from ingest import channel_month_pull as cm


class FakeClient:
    def __init__(self, pages):
        self.pages = pages
        self.calls = []

    def call(self, method, params, max_retries=3):
        self.calls.append(params)
        key = (params.get("query"), params["sort_direction"])
        records = self.pages.get(key, [])
        return {"channel_analytics": records, "num_found": len(records)}


def rec(cid, name):
    return {"channel_id": cid, "name": name}


def test_token_heads_take_the_first_letter_of_every_token():
    assert cm.token_heads("welcome-to-hack-club") == {"w", "t", "h", "c"}
    assert cm.token_heads("2026-hackathon") == {"2", "h"}


def test_only_latin_letters_and_digits_are_queryable_shards():
    heads = {"a", "z", "0", "9", "é", "ø", "α", "в", "中", "か"}
    assert cm.queryable_shards(heads) == ["0", "9", "a", "z"]


def test_astral_plane_names_yield_no_shard_at_all():
    assert cm.token_heads("𒈙𒈙𒈙") == set()
    assert cm.queryable_shards(cm.token_heads("𒈙𒈙𒈙")) == []


def test_sweep_dedupes_overlapping_shards_and_lands_only_fresh_records():
    client = FakeClient({
        ("a", "asc"): [rec("C1", "alpha"), rec("C2", "banana")],
        ("b", "asc"): [rec("C2", "banana"), rec("C3", "bravo")],
    })
    found, landed = {}, []
    cm.MIN_SECONDS_PER_CALL = 0
    truncated = cm.sweep(client, "2026-08", ["a", "b"], found, landed.append)
    assert truncated == []
    assert sorted(found) == ["C1", "C2", "C3"]
    assert [[r["channel_id"] for r in batch] for batch in landed] == [["C1", "C2"], ["C3"]]


def test_a_shard_whose_num_found_exceeds_its_page_is_reported_truncated():
    class Truncating(FakeClient):
        def call(self, method, params, max_retries=3):
            return {"channel_analytics": [rec("C1", "a")], "num_found": 900}
    cm.MIN_SECONDS_PER_CALL = 0
    cm.SPLIT_DEPTH = 0
    try:
        truncated = cm.sweep(Truncating({}), "2026-08", ["a"], {}, None)
    finally:
        cm.SPLIT_DEPTH = 3
    assert truncated == ["a"]


def test_tail_sweep_adds_only_channels_the_shards_missed():
    client = FakeClient({
        (None, "desc"): [rec("C9", "鏡音レン"), rec("C1", "alpha")],
    })
    found = {"C1": rec("C1", "alpha")}
    landed = []
    added = cm.tail_sweep(client, "2026-08", found, landed.append)
    assert added == 1
    assert sorted(found) == ["C1", "C9"]
    assert [r["channel_id"] for r in landed[0]] == ["C9"]
    assert client.calls[0]["sort_direction"] == "desc"
    assert "query" not in client.calls[0]


def test_absorb_reports_zero_when_nothing_is_new():
    found = {"C1": rec("C1", "a")}
    assert cm.absorb([rec("C1", "a")], found, None) == 0
