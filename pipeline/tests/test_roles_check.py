from checks import roles


class Cluster:
    def __init__(self, present, counts=0):
        self.present = present
        self.counts = counts

    def execute(self, sql, params=None):
        self.last = [(name,) for name in self.present] if "pg_roles" in sql else [(self.counts,)]
        return self

    def fetchall(self):
        return self.last

    def fetchone(self):
        return self.last[0]


def named(results):
    return {assertion: (status, observed) for assertion, status, observed, _ in results}


def test_three_roles_read_as_the_separated_mode():
    got = named(check(conn) for check in roles.CHECKS for conn in [Cluster(roles.EXPECTED_ROLES)])
    status, observed = got["the deployment mode is declared"]
    assert status == "pass"
    assert roles.SEPARATED_MODE in observed


def test_a_shared_login_is_a_known_mode_not_a_failure():
    conn = Cluster([])
    assertion, status, observed, _ = roles.the_deployment_mode_is_declared(conn)
    assert (assertion, status) == ("the deployment mode is declared", "pass")
    assert roles.SHARED_MODE in observed
    assert "capability checks" in observed


def test_the_separation_checks_are_skipped_when_the_login_is_shared():
    for check in roles.CHECKS[1:]:
        assertion, status, observed, _ = check(Cluster(["rails_app"]))
        assert status == "skipped", assertion
        assert roles.SHARED_MODE in observed


def test_the_separation_checks_still_bite_when_the_roles_exist():
    for check in roles.CHECKS[1:]:
        assertion, status, _, _ = check(Cluster(roles.EXPECTED_ROLES, counts=3))
        assert status == "fail", assertion


def test_a_skipped_check_is_not_an_error():
    assert roles.severity_of("skipped") == "info"
    assert roles.severity_of("pass") == "info"
    assert roles.severity_of("fail") == "error"
