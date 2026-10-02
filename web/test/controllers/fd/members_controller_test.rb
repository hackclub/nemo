require "test_helper"

class Fd::MembersControllerTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  def someone_with_a_handle
    handle = Fd::Member.live.where.not(handle: [nil, ""]).where("length(handle) >= 4")
      .group(:handle).having("count(*) = 1").order(Arel.sql("min(user_id)")).limit(1).pluck(:handle).first
    handle && Fd::Member.live.find_by(handle: handle)
  end

  test "the pane endpoint answers a search with rows the pane filter can swap in" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))
    named = someone_with_a_handle
    skip "the corpus has no member with a handle of its own" if named.nil?

    get fd_member_pane_path(q: named.handle), headers: { "Accept" => "text/html" }

    assert_response :success
    assert_includes response.body, named.user_id
    assert_includes response.body, "pane-filter-target=\"row\""
    assert_not_includes response.body, "<html"
  end

  test "the pane endpoint with no term lists the default roster page" do
    sign_in_as(hold_role!("UTESTCM1", "community_manager"))

    get fd_member_pane_path, headers: { "Accept" => "text/html" }

    assert_response :success
    assert_includes response.body, "pane-filter-target=\"row\""
  end
end
