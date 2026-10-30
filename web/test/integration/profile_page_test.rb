require "test_helper"

class YouPageTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "profile assigns the signed in account's own summary" do
    staff = grant_role!("UYOU1", "community_manager")
    sign_in_as(staff)

    get profile_path

    assert_response :success
    assert_equal "UYOU1", @controller.view_assigns["profile"].user_id
  end

  test "profile ignores user_id and id params" do
    staff = grant_role!("UYOU2", "community_manager")
    sign_in_as(staff)

    get profile_path(user_id: "UELSE", id: "UELSE")

    assert_response :success
    assert_equal "UYOU2", @controller.view_assigns["profile"].user_id
  end

  test "profile renders every Profile::Summary span and assigns its span_key" do
    staff = grant_role!("UYOU3", "community_manager")
    sign_in_as(staff)

    Profile::Summary::SPANS.each_key do |key|
      get profile_path(span: key)

      assert_response :success, "span=#{key} must render"
      assert_equal key, @controller.view_assigns["profile"].span_key
    end
  end

  test "profile with an unknown span falls back to DEFAULT_SPAN" do
    staff = grant_role!("UYOU4", "community_manager")
    sign_in_as(staff)

    get profile_path(span: "900d; drop table raw.message")

    assert_response :success
    assert_equal Profile::Summary::DEFAULT_SPAN, @controller.view_assigns["profile"].span_key
  end

  test "profile renders for an account with no data and any? is false" do
    staff = grant_role!("UYOUNEW", "community_manager")
    sign_in_as(staff)

    get profile_path

    assert_response :success
    assert_not @controller.view_assigns["profile"].any?
  end

  test "profile uses the mn_tz cookie as zone" do
    staff = grant_role!("UYOU5", "community_manager")
    sign_in_as(staff)

    cookies[:mn_tz] = "Asia/Kolkata"
    get profile_path

    assert_response :success
    assert_equal "Asia/Kolkata", @controller.view_assigns["profile"].zone
  end

  test "profile renders for an account with no role" do
    Account.find_or_create_by!(user_id: "UYOUPLAIN")
    sign_in_as(Account.find("UYOUPLAIN"))

    get profile_path

    assert_response :success
  end

  test "profile signed out redirects to login" do
    get profile_path

    assert_redirected_to login_path
  end

  test "community page links to profile" do
    staff = grant_role!("UYOU6", "community_manager")
    sign_in_as(staff)

    get community_path

    assert_response :success
    assert_select "a[href=?]", profile_path
  end
end
