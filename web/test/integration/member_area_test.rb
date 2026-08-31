require "test_helper"

class MemberAreaTest < ActionDispatch::IntegrationTest
  setup do
    @member = Staff.create!(user_id: "UMEMBER1")
    @staff = Staff.create!(user_id: "UBOSS1", community_manager: true)
  end

  def gated_paths
    [root_path, fd_root_path, fd_cases_path, fd_members_path, fd_settings_path,
     fd_audit_path, fd_decisions_path, fd_search_path, channels_path, engine_path,
     acquisition_journey_path]
  end

  test "a member with no role signs in and lands on their own page" do
    sign_in_as(@member)

    assert_redirected_to you_api_path
    follow_redirect!
    assert_response :success
  end

  test "a member with no role holds no permission at all" do
    assert_nil @member.role
    Fd::Permission.keys.each do |key|
      assert_not @member.may?(key), "a member with no role must not hold #{key}"
    end
  end

  test "every other page is still shut to a member with no role" do
    sign_in_as(@member)

    gated_paths.each do |path|
      get path
      assert_redirected_to auth_failure_path(message: "not_allowlisted"),
        "#{path} let a member with no role through"
    end
  end

  test "a member with no role cannot write to fire engine either" do
    kase = make_case

    sign_in_as(@member)
    post fd_case_claim_path(kase)

    assert_redirected_to auth_failure_path(message: "not_allowlisted")
    assert_empty kase.reload.assignees
  end

  test "a json request from a member with no role is refused, not redirected" do
    sign_in_as(@member)
    get fd_search_path(format: :json)

    assert_response :unauthorized
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
      extra: { raw_info: { "slack_id" => "../../etc/passwd" } }
    )
    get "/auth/hackclub/callback"

    assert_redirected_to auth_failure_path(message: "no_slack_id")

    get you_api_path
    assert_redirected_to login_path
  end

  test "the member page shows no fire engine and no analytics in the rail" do
    sign_in_as(@member)
    get you_api_path

    assert_select ".rail-item[href=?]", you_api_path
    assert_select ".rail-item[href=?]", fd_cases_path, count: 0
    assert_select ".rail-item[href=?]", channels_path, count: 0
    assert_select ".rail-item[href=?]", engine_path, count: 0
    assert_select ".rail-find", { count: 0 }, "the search palette is firefighters only"
  end

  test "a firefighter keeps their whole rail and gains the account section" do
    sign_in_as(@staff)
    get you_api_path

    assert_response :success
    assert_select ".rail-item[href=?]", you_api_path
    assert_select ".rail-item[href=?]", fd_cases_path
  end

  test "signing in as a firefighter still lands on the dashboard, not the member page" do
    sign_in_as(@staff)

    assert_redirected_to root_path
  end

  test "the sign in page sends a signed in member on rather than looping" do
    sign_in_as(@member)
    get login_path

    assert_redirected_to you_api_path
  end
end
