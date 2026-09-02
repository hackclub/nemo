ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

connected_to = ActiveRecord::Base.connection.current_database
unless connected_to.end_with?("_test")
  abort <<~MESSAGE
    Refusing to run tests against #{connected_to.inspect}.

    The suite truncates fixture tables and writes real rows, so it needs its own
    database whose name ends in _test. Build one with infra/test-db.sh, or point
    POSTGRES_TEST_DB at an existing one.
  MESSAGE
end

module ActiveSupport
  class TestCase
    parallelize(workers: 1)

    fixtures :all

    def hold_role!(user_id, role)
      Staff.find_or_create_by!(user_id: user_id)
      Authz::Grant.give!(user_id, kind: "role", name: role, by: "test")
      Current.forget_roles
      Staff.find(user_id)
    end

    def drop_roles!(user_id)
      Authz::Grant.live.for_person(user_id).roles.find_each { |row| row.take_back!(by: "test") }
      Current.forget_roles
    end

    def move_capability!(role, key, allowed, by: "test")
      Authz::Override.upsert({ role: role, capability: key, allowed: allowed,
                               changed_by: by, changed_at: Time.current },
        unique_by: %i[role capability])
      Current.forget_roles
    end

    def make_case(subject: "USUB", assign: nil, **attrs)
      kase = Fd::Case.create!({ opened_by: "UFF1", opened_at: 2.days.ago }.merge(attrs))
      kase.add_subject!(subject) if subject
      Array(assign).each { |user_id| kase.assign!(user_id) }
      kase
    end

    def sign_in_as(staff)
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:hackclub] = OmniAuth::AuthHash.new(
        provider: "hackclub",
        uid: "ident!#{staff.user_id}",
        info: {},
        extra: { raw_info: { "slack_id" => staff.user_id } }
      )
      get "/auth/hackclub/callback"
    end
  end
end
