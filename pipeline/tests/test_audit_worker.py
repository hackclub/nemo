from jobs import audit_worker


def lane_names(lanes):
    return [name for name, *_ in lanes]


def test_the_audit_backfill_lane_is_on_by_default(monkeypatch):
    monkeypatch.delenv("AUDIT_BACKFILL", raising=False)

    assert audit_worker.lane_enabled("backfill")


def test_the_access_backfill_lane_is_off_by_default(monkeypatch):
    monkeypatch.delenv("AUDIT_ACCESS_BACKFILL", raising=False)

    assert not audit_worker.lane_enabled("access_backfill")


def test_lanes_without_a_switch_always_run():
    assert audit_worker.lane_enabled("tail")
    assert audit_worker.lane_enabled("access")


def test_switch_values_are_read_case_insensitively(monkeypatch):
    for value in ("0", "off", "No", " FALSE "):
        monkeypatch.setenv("AUDIT_BACKFILL", value)
        assert not audit_worker.lane_enabled("backfill"), value

    for value in ("1", "on", "yes", "true"):
        monkeypatch.setenv("AUDIT_ACCESS_BACKFILL", value)
        assert audit_worker.lane_enabled("access_backfill"), value


def test_wanted_lanes_leaves_out_switched_off_lanes(monkeypatch):
    monkeypatch.setenv("AUDIT_BACKFILL", "off")
    monkeypatch.delenv("AUDIT_ACCESS_BACKFILL", raising=False)

    names = lane_names(audit_worker.wanted_lanes())

    assert "backfill" not in names
    assert "access_backfill" not in names
    assert names[0] == "tail"


def test_wanted_lanes_runs_every_lane_when_every_switch_is_on(monkeypatch):
    monkeypatch.delenv("AUDIT_BACKFILL", raising=False)
    monkeypatch.setenv("AUDIT_ACCESS_BACKFILL", "on")
    monkeypatch.setenv("AUDIT_LOGIN_BACKFILL", "on")
    monkeypatch.delenv("AUDIT_BACKFILL_SETS", raising=False)

    names = lane_names(audit_worker.wanted_lanes())

    assert names == lane_names(audit_worker.LANES)


def test_the_login_backfill_lane_is_off_by_default(monkeypatch):
    monkeypatch.delenv("AUDIT_LOGIN_BACKFILL", raising=False)

    assert not audit_worker.lane_enabled("login_backfill")
