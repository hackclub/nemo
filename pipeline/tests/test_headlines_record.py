from checks import headlines


class Recorder:
    def __init__(self):
        self.rows = []
        self.committed = False

    def cursor(self):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, params):
        self.rows.append(params)

    def commit(self):
        self.committed = True


def test_verdict_states_map_to_the_three_quality_statuses():
    assert headlines.STATUS_OF["ok"] == "pass"
    assert headlines.STATUS_OF["known"] == "pass"
    assert headlines.STATUS_OF["differs"] == "fail"
    assert headlines.STATUS_OF["stale"] == "fail"
    assert headlines.STATUS_OF["no data"] == "warn"


def test_every_verdict_is_recorded_with_its_delta_and_second_source():
    conn = Recorder()
    results = [
        ("total members", "count", "team.stats", 196670, 196670.0, "ok", 0.0),
        ("claim rate, percent", "rate", "team.stats", 65.9, 66.2, "known", -0.0045),
        ("channel count", "count", "conversations.list", 13400, 13466, "differs", -0.0049),
        ("top poster", "count", "getMemberAnalytics", None, None, "no data", None),
    ]
    assert headlines.record_verdicts(conn, 42, results) == 4
    assert conn.committed
    statuses = [row[3] for row in conn.rows]
    assert statuses == ["pass", "pass", "fail", "warn"]
    severities = [row[2] for row in conn.rows]
    assert severities == ["info", "info", "error", "warn"]
    assert conn.rows[0][0] == 42
    assert conn.rows[0][1] == "count:total members"
    assert "+0.00%" in conn.rows[0][4]
    assert conn.rows[2][5] == "13466 from conversations.list"
    assert conn.rows[3][4] is None
