require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "index redirects community manager to fd_root_path" do
    staff = grant_role!("UTESTCM1", "community_manager")
    sign_in_as(staff)

    get root_path

    assert_redirected_to fd_root_path
  end

  test "community returns success for community manager" do
    staff = grant_role!("UTESTCM2", "community_manager")
    sign_in_as(staff)

    get community_path

    assert_response :success
  end

  test "index returns success for gardener without case.read" do
    staff = grant_role!("UTESTGA1", "gardener")
    sign_in_as(staff)

    get root_path

    assert_response :success
  end

  test "index returns success when fire_engine flag is off" do
    staff = grant_role!("UTESTCM3", "community_manager")
    Fd::Flag.set!("fire_engine", false, by: staff.user_id)
    sign_in_as(staff)

    get root_path

    assert_response :success
  end

  test "viewer_zone reads the mn_tz cookie" do
    staff = grant_role!("UTESTTZ1", "community_manager")
    sign_in_as(staff)

    cookies[:mn_tz] = "Asia/Kolkata"
    get community_path

    assert_response :success
    assert_equal "Asia/Kolkata", @controller.send(:viewer_zone)
  end

  test "viewer_zone falls back to UTC for an unknown mn_tz" do
    staff = grant_role!("UTESTTZ2", "community_manager")
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

  test "index returns success for account with no roles" do
    staff = Account.create!(user_id: "UTESTNONE1")
    sign_in_as(staff)

    get root_path

    assert_response :success
  end
end
