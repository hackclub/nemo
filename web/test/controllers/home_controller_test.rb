require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "community manager sees the home dashboard" do
    staff = Staff.create!(user_id: "UTESTCM1", community_manager: true)
    sign_in_as(staff)

    get root_path

    assert_response :success
    assert_select ".kpis .card .kpi-val", minimum: 4
  end

  test "unauthenticated visitor is redirected to login" do
    get root_path

    assert_redirected_to login_path
  end

  test "a staff row with no roles cannot sign in, so it never reaches the dashboard" do
    staff = Staff.create!(user_id: "UTESTNONE1")
    sign_in_as(staff)
    assert_redirected_to auth_failure_path(message: "not_allowlisted")

    get root_path
    assert_redirected_to login_path
  end
end
