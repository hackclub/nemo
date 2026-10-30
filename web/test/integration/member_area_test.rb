require "test_helper"

class MemberAreaTest < ActionDispatch::IntegrationTest
  setup do
    @member = Account.create!(user_id: "UMEMBER1")
    @staff = grant_role!("UBOSS1", "community_manager")
  end

  def gated_paths
    [fd_root_path, fd_cases_path, fd_members_path, fd_audit_path, fd_search_path,
     engine_path, admin_root_path]
  end

  test "sign in without a role redirects to root and renders it" do
    sign_in_as(@member)

    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
  end

  test "account without a role lacks every capability except every-account keys" do
    Authz.keys.reject { |key| Authz.every_account?(key) }.each do |key|
      assert_not @member.may?(key), "account without a role must not have #{key}"
    end
  end

  test "gated paths redirect an account without a role to root" do
    sign_in_as(@member)

    gated_paths.each do |path|
      get path
      assert_redirected_to root_path, "#{path} must redirect an account without a role"
    end
  end

  test "case claim without a role redirects to root and leaves assignees empty" do
    kase = make_case

    sign_in_as(@member)
    post fd_case_claim_path(kase)

    assert_redirected_to root_path
    assert_empty kase.reload.assignees
  end

  test "json search without a role returns forbidden" do
    sign_in_as(@member)
    get fd_search_path(format: :json)

    assert_response :forbidden
  end

  test "settings keys signed out redirects to login" do
    get settings_keys_path

    assert_redirected_to login_path
  end

  test "settings keys after logout redirects to login" do
    sign_in_as(@member)
    get settings_keys_path
    assert_response :success

    delete logout_path
    get settings_keys_path

    assert_redirected_to login_path
  end

  test "auth callback with a non-slack uid redirects to failure and creates no session" do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:hackclub] = OmniAuth::AuthHash.new(
      provider: "hackclub", uid: "ident!nonsense", info: {},
      extra: { raw_info: {} }
    )
    get "/auth/hackclub/callback"

    assert_redirected_to auth_failure_path(message: "no_slack_id")

    get settings_keys_path
    assert_redirected_to login_path
  end

  test "rail for an account without a role has no fire engine or admin links" do
    sign_in_as(@member)
    get settings_keys_path

    assert_response :success
    assert_select ".switcher-row[href=?]", fd_root_path, count: 0
    assert_select ".switcher-row[href=?]", admin_root_path, count: 0
  end

  test "rail for a community manager links fire engine and admin" do
    sign_in_as(@staff)
    get settings_keys_path

    assert_response :success
    assert_select ".switcher-row[href=?]", fd_root_path
    assert_select ".switcher-row[href=?]", admin_root_path
  end

  test "login page signed in redirects to root" do
    sign_in_as(@member)
    get login_path

    assert_redirected_to root_path
  end
end
