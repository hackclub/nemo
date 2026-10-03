ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

ENV.delete("PROMETHEUS_BASE_URL")

connected_to = ActiveRecord::Base.connection.current_database
unless connected_to.end_with?("_test")
  abort <<~MESSAGE
    Refusing to run tests against #{connected_to.inspect}.

    The suite truncates fixture tables and writes real rows, so it needs its own
    database whose name ends in _test. Build one with infra/test-db.sh, or point
    POSTGRES_TEST_DB at an existing one.
  MESSAGE
end

module PipelineConnection
  def self.connection
    @connection ||= begin
      config = ApplicationRecord.connection_db_config.configuration_hash
      PG::Connection.new(
        host: config[:host], port: config[:port], dbname: config[:database],
        user: [ENV["PIPELINE_DB_USER"], "pipeline_writer"].find { |v| !v.to_s.empty? },
        password: [ENV["PIPELINE_DB_PASSWORD"], ENV["POSTGRES_PASSWORD"],
                   "change_me"].find { |v| !v.to_s.empty? }
      )
    end
  end
end

module SeedsPipelineTables
  extend ActiveSupport::Concern

  included do
    teardown { drop_pipeline_seeds! }
  end

  def pipeline_seeds
    @pipeline_seeds ||= []
  end

  def as_pipeline(sql, *binds)
    PipelineConnection.connection.exec(
      binds.empty? ? sql : ApplicationRecord.sanitize_sql([sql, *binds])
    )
  end

  def seeded!(table, column, value)
    pipeline_seeds << [table, column, value]
    value
  end

  def drop_pipeline_seeds!
    pipeline_seeds.reverse_each do |table, column, value|
      as_pipeline("DELETE FROM #{table} WHERE #{column} = ?", value)
    end
    pipeline_seeds.clear
  end

  def member!(user_id, email: nil, handle: nil)
    as_pipeline("INSERT INTO fd.member (user_id, handle) VALUES (?, ?) " \
                "ON CONFLICT (user_id) DO UPDATE SET handle = EXCLUDED.handle",
      user_id, handle || user_id.downcase)
    seeded!("fd.member", "user_id", user_id)
    return user_id if email.nil?

    as_pipeline("INSERT INTO fd.member_identity (user_id, email) VALUES (?, ?) " \
                "ON CONFLICT (user_id) DO UPDATE SET email = EXCLUDED.email", user_id, email)
    seeded!("fd.member_identity", "user_id", user_id)
    user_id
  end
end

module ActiveSupport
  class TestCase
    parallelize(workers: 1)

    fixtures :all

    WRITE_PRIVILEGES = %w[INSERT UPDATE DELETE TRUNCATE].freeze

    def write_grants_on(qualified_table, role: "rails_app")
      WRITE_PRIVILEGES.select do |privilege|
        ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql([
          "SELECT has_table_privilege(?, ?, ?)", role, qualified_table, privilege
        ]))
      end
    end

    def assert_read_only!(qualified_table, role: "rails_app")
      grants = write_grants_on(qualified_table, role: role)
      assert_empty grants,
        "#{role} may #{grants.join(', ')} on #{qualified_table}; it must only read it"
      assert ApplicationRecord.connection.select_value(ApplicationRecord.sanitize_sql([
        "SELECT has_table_privilege(?, ?, 'SELECT')", role, qualified_table
      ])), "#{role} cannot read #{qualified_table} either, so the grant proves nothing"
      assert_includes write_grants_on(qualified_table, role: "pipeline_writer"), "INSERT",
        "#{qualified_table} is nobody's to write, so the grant proves nothing"
    end

    def hold_role!(user_id, role)
      Account.find_or_create_by!(user_id: user_id)
      Authz::Grant.give!(user_id, kind: "role", name: role, by: "test")
      Current.forget_roles
      Account.find(user_id)
    end

    def drop_roles!(user_id)
      Authz::Grant.live.for_person(user_id).roles.find_each { |row| row.revoke!(by: "test") }
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

    def make_app!(owner, name: "Toolbox", approved: true, by: "UBOSS")
      app = Api::App.register!(owner, name: name, blurb: "answers a question for the team")
      Api::Approval.grant!(app.id, by: by) if approved
      app
    end

    def with_a_real_cache
      was = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = was
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
