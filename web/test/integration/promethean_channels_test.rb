require "test_helper"

class PrometheanChannelsTest < ActionDispatch::IntegrationTest
  PROMETHEAN_USER_ID = "UPROMCH01".freeze
  UNMEASURED_CHANNEL = "CGHOSTNOTHERE".freeze

  setup do
    @staff = Account.find_or_create_by!(user_id: PROMETHEAN_USER_ID)
    @channel = Analytics::DimChannel.where(archived: false).first
    Prometheus::Appointment.delete_all
    Current.forget_roles
  end

  teardown do
    Prometheus::Appointment.delete_all
    Current.forget_roles
  end

  def create_appointment(channel_id, role = "manager")
    Prometheus::Appointment.insert_all!([
      { user_id: PROMETHEAN_USER_ID, channel_id: channel_id, role: role, seen_at: Time.current }
    ])
    Current.forget_roles
  end

  Prometheus::Appointment::ROLES.each do |role|
    test "#{role} appointment grants the promethean role and channel access" do
      skip "no measured channel in the warehouse" if @channel.nil?
      create_appointment(@channel.channel_id, role)

      assert_equal ["promethean"], Authz.effective_roles(PROMETHEAN_USER_ID)
      assert Channels::Audience.may_see?(@staff, @channel.channel_id)
      assert_includes Channels::Audience.for(@staff).pluck(:channel_id), @channel.channel_id
    end

    test "unmeasured_for lists a #{role} channel missing from the warehouse" do
      create_appointment(UNMEASURED_CHANNEL, role)

      assert_equal [UNMEASURED_CHANNEL], Channels::Audience.unmeasured_for(@staff)
      assert Channels::Audience.may_see?(@staff, UNMEASURED_CHANNEL)
    end

    test "channel page for a #{role} unmeasured channel shows analytics unavailable" do
      create_appointment(UNMEASURED_CHANNEL, role)
      sign_in_as(@staff)

      get channel_path(UNMEASURED_CHANNEL)

      assert_response :success
      assert_match(/Analytics unavailable/, response.body)
      assert_match UNMEASURED_CHANNEL, response.body
    end
  end

  test "channel page without an appointment redirects to channels" do
    create_appointment(UNMEASURED_CHANNEL)
    sign_in_as(@staff)

    get channel_path("CSOMEONEELSE")

    assert_redirected_to channels_path(q: "CSOMEONEELSE")
  end

  test "channels index lists the unmeasured channel with no data" do
    create_appointment(UNMEASURED_CHANNEL)
    sign_in_as(@staff)

    get channels_path

    assert_response :success
    assert_match UNMEASURED_CHANNEL, response.body
    assert_match(/No data/, response.body)
  end

  test "grant of the promethean role raises NotAllowedError" do
    assert_not_includes Authz.grantable_roles, "promethean"
    assert_raises(Authz::Grant::NotAllowedError) do
      Authz::Grant.grant!(PROMETHEAN_USER_ID, kind: "role", name: "promethean", by: "test")
    end
  end
end
