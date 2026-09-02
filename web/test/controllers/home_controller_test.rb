require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "community manager sees the home dashboard" do
    staff = hold_role!("UTESTCM1", "community_manager")
    sign_in_as(staff)

    get root_path

    assert_response :success
    assert_select ".kpis .card .kpi-val", minimum: 4
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
    assert_select ".card-title", text: "Open to everyone", count: 0,
      message: "the overview is open to every signed-in member now"
  end
end
