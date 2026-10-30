require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:hackclub] = nil
  end

  test "allowlisted slack id signs in" do
    grant_role!("UTESTALLOWED", "community_manager")
    mock_hca_auth("UTESTALLOWED")

    get "/auth/hackclub/callback"

    assert_redirected_to root_path
    assert_equal "UTESTALLOWED", session[:user_id]
  end

  test "callback with account without grants signs in" do
    Account.create!(user_id: "UTESTNOGRANT")
    mock_hca_auth("UTESTNOGRANT")

    get "/auth/hackclub/callback"

    assert_redirected_to root_path
    assert_equal "UTESTNOGRANT", session[:user_id]
    assert_equal "Signed in", flash[:notice], "flash notice names no role"
  end

  test "callback with unknown slack id creates account and signs in" do
    mock_hca_auth("UNOTALLOWED")

    get "/auth/hackclub/callback"

    assert_redirected_to root_path
    assert_equal "UNOTALLOWED", session[:user_id]
    assert Account.exists?("UNOTALLOWED")
  end

  test "callback without slack_id claim redirects to auth failure" do
    OmniAuth.config.mock_auth[:hackclub] = OmniAuth::AuthHash.new(
      provider: "hackclub",
      uid: "ident!nofoo",
      info: {},
      extra: { raw_info: {} }
    )

    get "/auth/hackclub/callback"

    assert_redirected_to auth_failure_path(message: "no_slack_id")
  end

  test "logout clears session and redirects to login" do
    grant_role!("UTESTLOGOUT", "community_manager")
    mock_hca_auth("UTESTLOGOUT")
    get "/auth/hackclub/callback"
    assert_equal "UTESTLOGOUT", session[:user_id]

    delete "/logout"

    assert_redirected_to login_path
    assert_nil session[:user_id]
  end

  private

  def mock_hca_auth(slack_id)
    OmniAuth.config.mock_auth[:hackclub] = OmniAuth::AuthHash.new(
      provider: "hackclub",
      uid: "ident!#{slack_id}",
      info: { name: "Test User" },
      extra: { raw_info: { "slack_id" => slack_id } }
    )
  end
end
