require "test_helper"

class MemberAreaTest < ActionDispatch::IntegrationTest
  setup do
    @member = Account.create!(user_id: "UMEMBER1")
    @staff = hold_role!("UBOSS1", "community_manager")
  end

  def gated_paths
    [fd_root_path, fd_cases_path, fd_members_path, fd_audit_path, fd_search_path,
     engine_path, acquisition_journey_path, admin_root_path]
  end

  test "a member with no role signs in and reaches the front door" do
    sign_in_as(@member)

    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
  end

  test "a member with no role holds no capability at all" do
    Authz.keys.each do |key|
      assert_not @member.may?(key), "a member with no role must not hold #{key}"
    end
  end

  test "the conduct and ops pages are still shut to a member with no role" do
    sign_in_as(@member)

    gated_paths.each do |path|
      get path
      assert_redirected_to root_path, "#{path} let a member with no role through"
    end
  end

  test "a member with no role cannot write to fire engine either" do
    kase = make_case

    sign_in_as(@member)
    post fd_case_claim_path(kase)

    assert_redirected_to root_path
    assert_empty kase.reload.assignees
  end

  test "a json request from a member with no role is refused, not redirected" do
    sign_in_as(@member)
    get fd_search_path(format: :json)

    assert_response :forbidden
  end

  test "signed out, the member page sends you to sign in" do
    get you_api_path

    assert_redirected_to login_path
  end

  test "signing out shuts the member page again" do
    sign_in_as(@member)
    get you_api_path
    assert_response :success

    delete logout_path
    get you_api_path

    assert_redirected_to login_path
  end

  test "an identity that is not a slack id is given no session at all" do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hackclub] = OmniAuth::AuthHash.new(
      provider: "hackclub", uid: "ident!nonsense", info: {},
      extra: { raw_info: {} }
    )
    get "/auth/hackclub/callback"

    assert_redirected_to auth_failure_path(message: "no_slack_id")

    get you_api_path
    assert_redirected_to login_path
  end

  test "the rail offers a member with no role no way into fire engine" do
    sign_in_as(@member)
    get you_api_path

    assert_response :success
    assert_select ".rail-btn[href=?]", fd_root_path, count: 0
    assert_select ".rail-btn[href=?]", admin_root_path, count: 0
  end

  test "a community manager keeps fire engine and admin in the rail" do
    sign_in_as(@staff)
    get you_api_path

    assert_response :success
    assert_select ".rail-btn[href=?]", fd_root_path
    assert_select ".rail-btn[href=?]", admin_root_path
  end

  test "the sign in page sends a signed in member on rather than looping" do
    sign_in_as(@member)
    get login_path

    assert_redirected_to root_path
  end
end
