require "test_helper"

class PrometheusMirrorTest < ActiveSupport::TestCase
  WHO = "UPROM0001".freeze
  NOWHERE = "http://127.0.0.1:9".freeze

  setup do
    ENV["PROMETHEUS_BASE_URL"] = "http://prometheus.test"
    Account.find_or_create_by!(user_id: WHO)
    Prometheus::Appointment.delete_all
    Rails.cache.delete("prometheus/checked/#{WHO}")
    Current.forget_roles
  end

  teardown do
    ENV.delete("PROMETHEUS_BASE_URL")
    Prometheus::Appointment.delete_all
    Current.forget_roles
  end

  def instead_of(name, answer)
    was = Prometheus::Roster.method(name)
    Prometheus::Roster.define_singleton_method(name) { |*| answer.respond_to?(:call) ? answer.call : answer }
    yield
  ensure
    Prometheus::Roster.define_singleton_method(name, was)
  end

  def held(user_id = WHO)
    Prometheus::Appointment.for_person(user_id).order(:channel_id).pluck(:channel_id, :role)
  end

  def holding(*channels)
    Prometheus::Mirror.settle(WHO, channels)
  end

  test "settling writes what Prometheus holds" do
    holding({ "channel_id" => "C1", "role" => "manager" },
      { "channel_id" => "C2", "role" => "moderator" })

    assert_equal [["C1", "manager"], ["C2", "moderator"]], held
  end

  test "only a manager appointment carries the role" do
    holding({ "channel_id" => "C1", "role" => "moderator" })
    assert_empty Authz.roles_held(WHO)

    holding({ "channel_id" => "C1", "role" => "manager" })
    assert_equal ["promethean"], Authz.roles_held(WHO)
  end

  test "a shrunk answer takes channels away" do
    holding({ "channel_id" => "C1", "role" => "manager" },
      { "channel_id" => "C2", "role" => "manager" })
    holding({ "channel_id" => "C1", "role" => "manager" })

    assert_equal [["C1", "manager"]], held
  end

  test "an unknown role or a blank channel is dropped rather than written" do
    holding({ "channel_id" => "C1", "role" => "owner" },
      { "channel_id" => "", "role" => "manager" },
      { "channel_id" => "C2", "role" => "manager" })

    assert_equal [["C2", "manager"]], held
  end

  test "the same channel twice does not break the write" do
    holding({ "channel_id" => "C1", "role" => "manager" },
      { "channel_id" => "C1", "role" => "manager" })

    assert_equal [["C1", "manager"]], held
  end

  test "an outage leaves what we already hold alone" do
    holding({ "channel_id" => "C1", "role" => "manager" })
    ENV["PROMETHEUS_BASE_URL"] = NOWHERE

    assert_not Prometheus::Mirror.refresh(WHO)
    assert_equal [["C1", "manager"]], held
  end

  test "nothing happens when no base url is configured" do
    holding({ "channel_id" => "C1", "role" => "manager" })
    ENV.delete("PROMETHEUS_BASE_URL")

    assert_not Prometheus::Mirror.refresh(WHO)
    assert_not Prometheus::Mirror.freshen(WHO)
    assert_equal [["C1", "manager"]], held
  end

  test "a reconcile refuses to empty the mirror" do
    holding({ "channel_id" => "C1", "role" => "manager" })

    instead_of(:every_appointment, [].each) do
      assert_not Prometheus::Mirror.reconcile_all
    end

    assert_equal [["C1", "manager"]], held
  end

  test "a reconcile replaces every row" do
    holding({ "channel_id" => "COLD", "role" => "manager" })
    rows = [{ "user_id" => "UOTHER01", "channel_id" => "CNEW", "role" => "manager" }]

    instead_of(:every_appointment, rows.each) do
      assert_equal 1, Prometheus::Mirror.reconcile_all
    end

    assert_empty held
    assert_equal [["CNEW", "manager"]], held("UOTHER01")
  end

  test "a reconcile that cannot reach Prometheus changes nothing" do
    holding({ "channel_id" => "C1", "role" => "manager" })
    ENV["PROMETHEUS_BASE_URL"] = NOWHERE

    assert_not Prometheus::Mirror.reconcile_all
    assert_equal [["C1", "manager"]], held
  end

  test "a second look inside the fresh window does not ask again" do
    was = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    holding({ "channel_id" => "C1", "role" => "manager" })

    assert Prometheus::Mirror.asking_again?(WHO)
    assert_not Prometheus::Mirror.asking_again?(WHO)
  ensure
    Rails.cache = was
  end

  test "somebody holding no appointment is never looked up" do
    assert_not Prometheus::Mirror.freshen("UNOBODY9")
  end
end
