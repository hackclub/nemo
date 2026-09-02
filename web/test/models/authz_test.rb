require "test_helper"

class AuthzTest < ActiveSupport::TestCase
  def rows(sql)
    ApplicationRecord.connection.select_all(sql).to_a
  end

  test "the catalogue Rails reads matches the tables SQL resolves against" do
    in_yaml = Authz.keys.sort
    in_table = rows("SELECT key FROM app.capability").map { |row| row["key"] }.sort

    assert_equal in_yaml, in_table,
      "db/capabilities.yml and app.capability disagree, run `nemo provision`"
  end

  test "every role baseline matches the projected table" do
    Authz.role_names.reject { |role| Authz.superadmin?(role) }.each do |role|
      in_table = rows(ApplicationRecord.sanitize_sql([
        "SELECT capability FROM app.role_capability WHERE role = ?", role
      ])).map { |row| row["capability"] }.sort

      assert_equal Authz.baseline(role).sort, in_table, "#{role} baseline has drifted"
    end
  end

  test "record scopes and flags match the projected table" do
    rows("SELECT key, record_scope, logged, every_account, locked FROM app.capability").each do |row|
      key = row["key"]
      wanted = Authz.record_scope(key)&.to_s
      if wanted.nil?
        assert_nil row["record_scope"], "#{key} scope"
      else
        assert_equal wanted, row["record_scope"], "#{key} scope"
      end
      assert_equal Authz.logged?(key), row["logged"], "#{key} logged"
      assert_equal Authz.every_account?(key), row["every_account"], "#{key} every_account"
      assert_equal Authz.locked?(key), row["locked"], "#{key} locked"
    end
  end

  test "an unknown capability is refused rather than treated as absent" do
    assert_raises(Authz::Unknown) { Authz.record_scope("case.explode") }
  end

  test "a scoped capability still answers the unscoped question for the UI" do
    assert_equal :assigned, Authz.record_scope("case.act")
    assert Authz.scoped?("case.act")
    assert_not Authz.scoped?("case.resolve")
  end

  test "nobody holds anything without a grant, apart from every-account keys" do
    nobody = Account.new(user_id: "UNOBODY9")

    assert Authz.may?(nobody, "slack.link")
    assert_not Authz.may?(nobody, "case.read")
    assert_not Authz.may?(nobody, "access.grant")
  end

  test "a nil account holds nothing at all" do
    assert_not Authz.may?(nil, "slack.link")
    assert_not Authz.may?(nil, "case.read")
  end
end
