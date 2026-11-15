require "test_helper"

class PrometheusMirrorTest < ActiveSupport::TestCase
  USER_ID = "UPROM0001".freeze
  UNREACHABLE_URL = "http://127.0.0.1:9".freeze

  setup do
    ENV["PROMETHEUS_BASE_URL"] = "http://prometheus.test"
    Account.find_or_create_by!(user_id: USER_ID)
    Prometheus::Appointment.delete_all
    Rails.cache.delete("prometheus/checked/#{USER_ID}")
    Current.forget_roles
  end

  teardown do
    ENV.delete("PROMETHEUS_BASE_URL")
    Prometheus::Appointment.delete_all
    Current.forget_roles
  end

  def stub_roster(name, result)
    original = Prometheus::Roster.method(name)
    Prometheus::Roster.define_singleton_method(name) { |*| result.respond_to?(:call) ? result.call : result }
    yield
  ensure
    Prometheus::Roster.define_singleton_method(name, original)
  end

  def appointments(user_id = USER_ID)
    Prometheus::Appointment.for_person(user_id).order(:channel_id).pluck(:channel_id, :role)
  end

  def replace_appointments(*channels)
    Prometheus::Mirror.replace_appointments(USER_ID, channels)
  end

  test "replace_appointments stores every given appointment" do
    replace_appointments({ "channel_id" => "C1", "role" => "manager" },
      { "channel_id" => "C2", "role" => "moderator" })

    assert_equal [["C1", "manager"], ["C2", "moderator"]], appointments
  end

  test "effective_roles includes promethean for a manager or moderator appointment" do
    replace_appointments({ "channel_id" => "C1", "role" => "moderator" })
    assert_equal ["promethean"], Authz.effective_roles(USER_ID)

    replace_appointments({ "channel_id" => "C1", "role" => "manager" })
    assert_equal ["promethean"], Authz.effective_roles(USER_ID)

    replace_appointments
    assert_empty Authz.effective_roles(USER_ID)
  end

  test "replace_appointments removes channels missing from the new list" do
    replace_appointments({ "channel_id" => "C1", "role" => "manager" },
      { "channel_id" => "C2", "role" => "manager" })
    replace_appointments({ "channel_id" => "C1", "role" => "manager" })

    assert_equal [["C1", "manager"]], appointments
  end

  test "replace_appointments skips an unknown role and a blank channel_id" do
    replace_appointments({ "channel_id" => "C1", "role" => "owner" },
      { "channel_id" => "", "role" => "manager" },
      { "channel_id" => "C2", "role" => "manager" })

    assert_equal [["C2", "manager"]], appointments
  end

  test "replace_appointments with a duplicate channel stores one row" do
    replace_appointments({ "channel_id" => "C1", "role" => "manager" },
      { "channel_id" => "C1", "role" => "manager" })

    assert_equal [["C1", "manager"]], appointments
  end

  test "refresh keeps stored appointments when Prometheus is unreachable" do
    replace_appointments({ "channel_id" => "C1", "role" => "manager" })
    ENV["PROMETHEUS_BASE_URL"] = UNREACHABLE_URL

    assert_not Prometheus::Mirror.refresh(USER_ID)
    assert_equal [["C1", "manager"]], appointments
  end

  test "refresh and refresh_if_due without a base url keep appointments" do
    replace_appointments({ "channel_id" => "C1", "role" => "manager" })
    ENV.delete("PROMETHEUS_BASE_URL")

    assert_not Prometheus::Mirror.refresh(USER_ID)
    assert_not Prometheus::Mirror.refresh_if_due(USER_ID)
    assert_equal [["C1", "manager"]], appointments
  end

  test "reconcile_all with an empty roster returns false and keeps rows" do
    replace_appointments({ "channel_id" => "C1", "role" => "manager" })

    stub_roster(:every_appointment, [].each) do
      assert_not Prometheus::Mirror.reconcile_all
    end

    assert_equal [["C1", "manager"]], appointments
  end

  test "reconcile_all replaces rows with the roster" do
    replace_appointments({ "channel_id" => "COLD", "role" => "manager" })
    rows = [{ "user_id" => "UOTHER01", "channel_id" => "CNEW", "role" => "manager" }]

    stub_roster(:every_appointment, rows.each) do
      assert_equal 1, Prometheus::Mirror.reconcile_all
    end

    assert_empty appointments
    assert_equal [["CNEW", "manager"]], appointments("UOTHER01")
  end

  test "reconcile_all keeps rows when Prometheus is unreachable" do
    replace_appointments({ "channel_id" => "C1", "role" => "manager" })
    ENV["PROMETHEUS_BASE_URL"] = UNREACHABLE_URL

    assert_not Prometheus::Mirror.reconcile_all
    assert_equal [["C1", "manager"]], appointments
  end

  test "check_due? is true once then false inside the fresh window" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    replace_appointments({ "channel_id" => "C1", "role" => "manager" })

    assert Prometheus::Mirror.check_due?(USER_ID)
    assert_not Prometheus::Mirror.check_due?(USER_ID)
  ensure
    Rails.cache = original_cache
  end

  test "refresh_if_due returns false for an unknown user" do
    assert_not Prometheus::Mirror.refresh_if_due("UNOBODY9")
  end
end
