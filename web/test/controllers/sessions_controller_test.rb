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

  test "sign in returns to the page that required it with its query" do
    grant_role!("UTESTRETURN", "community_manager")
    mock_hca_auth("UTESTRETURN")

    get engine_path(tab: "faults")
    assert_redirected_to login_path

    get "/auth/hackclub/callback"

    assert_redirected_to engine_path(tab: "faults")
    assert_equal "UTESTRETURN", session[:user_id]
    assert_nil session[:return_to]
  end

  test "sign in without permission for the requested page does not grant it" do
    Account.create!(user_id: "UTESTNOPERM")
    mock_hca_auth("UTESTNOPERM")

    get engine_path
    assert_redirected_to login_path

    get "/auth/hackclub/callback"
    assert_redirected_to engine_path

    follow_redirect!
    assert_redirected_to root_path
    assert_equal Community::Access.why_not(Account.find("UTESTNOPERM"), "ops.engine"), flash[:alert]
  end

  test "stored return path is used once" do
    grant_role!("UTESTONCE", "community_manager")
    mock_hca_auth("UTESTONCE")

    get engine_path
    get "/auth/hackclub/callback"
    assert_redirected_to engine_path

    delete "/logout"
    get "/auth/hackclub/callback"
    assert_redirected_to root_path
  end

  test "non-page requests do not store a return path" do
    get engine_path, headers: { "Accept" => "application/json" }
    assert_response :unauthorized
    assert_nil session[:return_to]

    get engine_path(format: :json)
    assert_nil session[:return_to]

    post engine_sync_path
    assert_redirected_to login_path
    assert_nil session[:return_to]

    get engine_path, headers: { "Turbo-Frame" => "panel" }
    assert_redirected_to login_path
    assert_nil session[:return_to]
  end

  test "failed authentication drops the stored return path" do
    OmniAuth.config.mock_auth[:hackclub] = OmniAuth::AuthHash.new(
      provider: "hackclub", uid: "ident!nofoo", info: {}, extra: { raw_info: {} }
    )

    get engine_path
    get "/auth/hackclub/callback"

    assert_redirected_to auth_failure_path(message: "no_slack_id")
    assert_nil session[:return_to]
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
