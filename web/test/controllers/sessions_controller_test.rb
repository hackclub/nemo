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
    Staff.create!(user_id: "UTESTALLOWED", community_manager: true)
    mock_hca_auth("UTESTALLOWED")

    get "/auth/hackclub/callback"

    assert_redirected_to root_path
    assert_equal "UTESTALLOWED", session[:user_id]
  end

  test "a staff row with no grant still signs in, holding nothing" do
    Staff.create!(user_id: "UTESTNOGRANT", community_manager: false)
    mock_hca_auth("UTESTNOGRANT")

    get "/auth/hackclub/callback"

    assert_redirected_to root_path
    assert_equal "UTESTNOGRANT", session[:user_id]
    assert_equal "Signed in", flash[:notice], "it must not claim a role they do not hold"
  end

  test "a slack id nobody has seen becomes a staff row on first sign in" do
    mock_hca_auth("UNOTALLOWED")

    get "/auth/hackclub/callback"

    assert_redirected_to root_path
    assert_equal "UNOTALLOWED", session[:user_id]
    assert Staff.exists?("UNOTALLOWED")
  end

  test "missing slack_id claim is rejected" do
    OmniAuth.config.mock_auth[:hackclub] = OmniAuth::AuthHash.new(
      provider: "hackclub",
      uid: "ident!nofoo",
      info: {},
      extra: { raw_info: {} }
    )

    get "/auth/hackclub/callback"

    assert_redirected_to auth_failure_path(message: "not_allowlisted")
  end

  test "logout clears the session" do
    Staff.create!(user_id: "UTESTLOGOUT", community_manager: true)
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
