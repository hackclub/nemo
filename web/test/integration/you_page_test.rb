require "test_helper"

class YouPageTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "a signed-in account sees its own page" do
    staff = hold_role!("UYOU1", "community_manager")
    sign_in_as(staff)

    get you_path

    assert_response :success
    assert_equal "UYOU1", @controller.view_assigns["profile"].user_id
  end

  test "somebody else's id in the query is never read" do
    staff = hold_role!("UYOU2", "community_manager")
    sign_in_as(staff)

    get you_path(user_id: "UELSE", id: "UELSE")

    assert_response :success
    assert_equal "UYOU2", @controller.view_assigns["profile"].user_id
  end

  test "every offered range renders and keeps its own span" do
    staff = hold_role!("UYOU3", "community_manager")
    sign_in_as(staff)

    You::Profile::SPANS.each_key do |key|
      get you_path(span: key)

      assert_response :success, "span=#{key} must render"
      assert_equal key, @controller.view_assigns["profile"].span_key
    end
  end

  test "a range nobody offered falls back to the default" do
    staff = hold_role!("UYOU4", "community_manager")
    sign_in_as(staff)

    get you_path(span: "900d; drop table raw.message")

    assert_response :success
    assert_equal You::Profile::DEFAULT_SPAN, @controller.view_assigns["profile"].span_key
  end

  test "an account with nothing measured still renders" do
    staff = hold_role!("UYOUNEW", "community_manager")
    sign_in_as(staff)

    get you_path

    assert_response :success
    assert_not @controller.view_assigns["profile"].any?
  end

  test "the clock follows the timezone the browser wrote" do
    staff = hold_role!("UYOU5", "community_manager")
    sign_in_as(staff)

    cookies[:mn_tz] = "Asia/Kolkata"
    get you_path

    assert_response :success
    assert_equal "Asia/Kolkata", @controller.view_assigns["profile"].zone
  end

  test "an account with no role at all still holds its own page" do
    Account.find_or_create_by!(user_id: "UYOUPLAIN")
    sign_in_as(Account.find("UYOUPLAIN"))

    get you_path

    assert_response :success
  end

  test "signed out is sent to login" do
    get you_path

    assert_redirected_to login_path
  end

  test "the community pane offers the page" do
    staff = hold_role!("UYOU6", "community_manager")
    sign_in_as(staff)

    get root_path

    assert_response :success
    assert_select "a[href=?]", you_path
  end
end
