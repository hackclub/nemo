from lib import breaker


def test_a_streak_counts_only_leading_transport_failures():
    rows = [("failed", "transport", False), ("failed", "transport", True), ("ok", None, None), ("failed", "transport", False)]
    assert breaker.streak_of(rows) == (2, True)
    assert breaker.streak_of([("failed", "upstream", False), ("failed", "transport", False)]) == (0, False)
    assert breaker.streak_of([("failed", "transport", True)] * 4) == (4, False)
    assert breaker.streak_of([]) == (0, False)


def test_source_scope_trips_at_three_and_credential_scope_at_three_sources():
    streaks = {"member_days": (3, False), "member_range": (1, False), "channel_range": (1, False), "team_stats": (0, False)}
    scopes = breaker.open_scopes(streaks)
    assert ("source", "member_days") in scopes
    assert ("credential", "internal") in scopes
    assert ("proxy", "proxy") not in scopes
    assert scopes[("source", "member_days")][0] == 3


def test_proxy_scope_needs_edge_answers_on_two_credentials_or_a_failed_heartbeat():
    streaks = {"member_days": (1, True), "member_history": (1, True)}
    assert ("proxy", "proxy") in breaker.open_scopes(streaks)
    assert ("proxy", "proxy") not in breaker.open_scopes({"member_days": (1, True), "member_range": (1, True)})
    assert ("proxy", "proxy") in breaker.open_scopes({}, proxy_down=True)


def test_covering_honours_overrides_and_scope_order():
    verdicts = [
        {"scope": "source", "key": "member_days", "overridden": True, "detail": "x"},
        {"scope": "credential", "key": "internal", "overridden": False, "detail": "y"},
    ]
    assert breaker.covering(verdicts, "member_days")["scope"] == "credential"
    assert breaker.covering(verdicts, "member_history") is None
    assert breaker.covering([{"scope": "proxy", "key": "proxy", "overridden": False, "detail": "z"}], "team_stats")["scope"] == "proxy"
