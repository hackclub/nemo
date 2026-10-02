require "test_helper"

class PrometheanChannelsTest < ActionDispatch::IntegrationTest
  WHO = "UPROMCH01".freeze
  GHOST = "CGHOSTNOTHERE".freeze

  setup do
    @staff = Account.find_or_create_by!(user_id: WHO)
    @measured = Analytics::DimChannel.where(archived: false).first
    Prometheus::Appointment.delete_all
    Current.forget_roles
  end

  teardown do
    Prometheus::Appointment.delete_all
    Current.forget_roles
  end

  def appoint(channel_id, role = "manager")
    Prometheus::Appointment.insert_all!([
      { user_id: WHO, channel_id: channel_id, role: role, seen_at: Time.current }
    ])
    Current.forget_roles
  end

  test "a manager appointment carries the role and the channel" do
    skip "no measured channel in the warehouse" if @measured.nil?
    appoint(@measured.channel_id)

    assert_equal ["promethean"], Authz.roles_held(WHO)
    assert Channels::Audience.may_see?(@staff, @measured.channel_id)
  end

  test "a moderator appointment carries nothing" do
    skip "no measured channel in the warehouse" if @measured.nil?
    appoint(@measured.channel_id, "moderator")

    assert_empty Authz.roles_held(WHO)
    assert_not Channels::Audience.may_see?(@staff, @measured.channel_id)
  end

  test "a channel the warehouse has never seen is listed as unmeasured" do
    appoint(GHOST)

    assert_equal [GHOST], Channels::Audience.unmeasured_for(@staff)
    assert Channels::Audience.may_see?(@staff, GHOST)
  end

  test "the unmeasured channel page explains itself rather than refusing" do
    appoint(GHOST)
    sign_in_as(@staff)

    get channel_path(GHOST)

    assert_response :success
    assert_match(/Analytics isn't available for this channel yet/, response.body)
    assert_match GHOST, response.body
  end

  test "a channel they hold nothing on is still refused" do
    appoint(GHOST)
    sign_in_as(@staff)

    get channel_path("CSOMEONEELSE")

    assert_redirected_to channels_path(q: "CSOMEONEELSE")
  end

  test "the index carries the unmeasured channel" do
    appoint(GHOST)
    sign_in_as(@staff)

    get channels_path

    assert_response :success
    assert_match GHOST, response.body
    assert_match(/no data for this channel yet/, response.body)
  end

  test "the promethean role cannot be handed out by hand" do
    assert_not_includes Authz.grantable_roles, "promethean"
    assert_raises(Authz::Grant::NotAllowed) do
      Authz::Grant.give!(WHO, kind: "role", name: "promethean", by: "test")
    end
  end
end
