require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "conduct staff land on the fire engine, not the dashboard" do
    staff = hold_role!("UTESTCM1", "community_manager")
    sign_in_as(staff)

    get root_path

    assert_redirected_to fd_root_path
  end

  test "conduct staff asking for the community overview get it" do
    staff = hold_role!("UTESTCM2", "community_manager")
    sign_in_as(staff)

    get community_path

    assert_response :success
  end

  test "somebody without case.read still lands on the dashboard" do
    staff = hold_role!("UTESTGA1", "gardener")
    sign_in_as(staff)

    get root_path

    assert_response :success
  end

  test "the fire engine flag being off leaves the landing alone" do
    staff = hold_role!("UTESTCM3", "community_manager")
    Fd::Flag.set!("fire_engine", false, by: staff.user_id)
    sign_in_as(staff)

    get root_path

    assert_response :success
  end

  test "the clock follows the timezone the browser wrote" do
    staff = hold_role!("UTESTTZ1", "community_manager")
    sign_in_as(staff)

    cookies[:mn_tz] = "Asia/Kolkata"
    get community_path

    assert_response :success
    assert_equal "Asia/Kolkata", @controller.send(:viewer_zone)
  end

  test "a timezone nobody has heard of falls back to UTC" do
    staff = hold_role!("UTESTTZ2", "community_manager")
    sign_in_as(staff)

    cookies[:mn_tz] = "Moon/Sea_of_Tranquility"
    get community_path

    assert_response :success
    assert_equal "UTC", @controller.send(:viewer_zone)
  end

  test "unauthenticated visitor is redirected to login" do
    get root_path

    assert_redirected_to login_path
  end

  test "a staff row with no roles reaches the front door, not the dashboard" do
    staff = Account.create!(user_id: "UTESTNONE1")
    sign_in_as(staff)

    get root_path

    assert_response :success
  end
end
