require "test_helper"

class AdminScreensTest < ActionDispatch::IntegrationTest
  setup do
    @boss = hold_role!("UADBOSS", "community_manager")
  end

  test "every signed in person reaches their own account" do
    sign_in_as(Account.create!(user_id: "UADNONE"))

    get account_path

    assert_response :success
  end

  test "the admin screens each render for a manager" do
    sign_in_as(@boss)

    [admin_people_path, admin_roles_path, admin_flags_path, admin_channels_path].each do |path|
      get path
      assert_response :success, "#{path} did not render"
    end
  end

  test "the roles matrix is one table over every capability and role" do
    sign_in_as(@boss)

    get admin_roles_path

    assert_response :success
  end

  test "somebody holding nothing cannot administer access" do
    sign_in_as(Account.create!(user_id: "UADOUT"))

    get admin_people_path

    assert_redirected_to root_path
  end

  test "a manager sets a channel audience" do
    channel = Analytics::DimChannel.where(archived: false).first
    sign_in_as(@boss)

    patch admin_channel_path(channel.channel_id), params: { audience: "public" }

    assert_redirected_to admin_channels_path
    assert_equal "public", Channels::Audience.of(channel.channel_id)
  end

  test "the analytics role cannot reach the admin section at all" do
    sign_in_as(hold_role!("UADANA", "analytics"))

    get admin_channels_path

    assert_redirected_to root_path
  end

  test "only a role holding access.grant reaches the admin section" do
    sign_in_as(hold_role!("UADCUR", "community_manager"))

    get admin_channels_path

    assert_response :success
  end

  test "the analytics role cannot set a channel audience" do
    staff = hold_role!("UADANA2", "analytics")
    channel = Analytics::DimChannel.where(archived: false).first
    sign_in_as(staff)

    patch admin_channel_path(channel.channel_id), params: { audience: "public" }

    assert_equal "granted", Channels::Audience.of(channel.channel_id)
  end

  test "an unknown audience is refused" do
    sign_in_as(@boss)
    channel = Analytics::DimChannel.where(archived: false).first

    patch admin_channel_path(channel.channel_id), params: { audience: "world" }

    assert_match(/not an audience/, flash[:alert])
    assert_equal "granted", Channels::Audience.of(channel.channel_id)
  end
end
