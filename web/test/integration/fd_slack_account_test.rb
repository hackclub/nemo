require "test_helper"

class FdSlackAccountTest < ActionDispatch::IntegrationTest
  def stub_oauth(name, result)
    original = Slack::Oauth.method(name)
    Slack::Oauth.define_singleton_method(name) do |*args, **kwargs|
      result.respond_to?(:call) ? result.call(*args, **kwargs) : result
    end
    yield
  ensure
    Slack::Oauth.define_singleton_method(name, original)
  end

  ENV_KEYS = %w[NEMO_CLIENT_ID NEMO_CLIENT_SECRET SLACK_TEAM_ID].freeze

  setup do
    @me = grant_role!("UME", "community_manager")
    @original_env = ENV.slice(*ENV_KEYS)
    ENV_KEYS.each { |name| ENV.delete(name) }
    ENV["NEMO_CLIENT_ID"] = "1.2"
    ENV["NEMO_CLIENT_SECRET"] = "shh"
  end

  teardown do
    ENV_KEYS.each { |name| ENV.delete(name) }
    @original_env.each { |name, value| ENV[name] = value }
  end

  def granted(id: "UME", scope: "chat:write", token: "xoxp-real", team: "T0FIRE")
    { "ok" => true, "team" => { "id" => team },
      "authed_user" => { "id" => id, "scope" => scope, "access_token" => token } }
  end

  def start_linking
    post fd_slack_account_path
  end

  def entries(verb)
    Fd::AuditEntry.where(entity_type: "slack_account", verb: verb)
  end

  test "slack account create signed out redirects to login" do
    start_linking
    assert_redirected_to login_path
  end

  test "slack account create redirects to slack authorize with user_scope and state" do
    sign_in_as(@me)
    start_linking

    assert_response :redirect
    sent = URI.parse(response.location)
    query = Rack::Utils.parse_query(sent.query)

    assert_equal "slack.com", sent.host
    assert_equal "/oauth/v2/authorize", sent.path
    assert_equal "chat:write", query["user_scope"]
    assert_equal "1.2", query["client_id"]
    assert_equal fd_slack_account_callback_url, query["redirect_uri"]
    assert query["state"].present?, "state param is blank"
  end

  test "slack account create without NEMO_CLIENT_ID redirects to account with alert" do
    ENV.delete("NEMO_CLIENT_ID")
    sign_in_as(@me)
    start_linking

    assert_redirected_to account_path
    assert_match(/Slack linking not configured/, flash[:alert])
  end

  test "slack account callback with matching state stores token and creates linked entry" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    stub_oauth(:exchange, granted) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    row = Fd::StaffSlack.active_for("UME")
    assert_not_nil row
    assert_equal "xoxp-real", row.user_token
    assert_equal "T0FIRE", row.team_id
    assert_equal "chat:write", row.scopes
    assert_equal 1, entries("linked").count
    assert_no_match(/xoxp-real/, entries("linked").sole.after.to_json)
  end

  test "StaffSlack.store! does not store user_token as plaintext" do
    sign_in_as(@me)
    Fd::StaffSlack.store!("UME", token: "xoxp-real", team_id: "T0FIRE", scopes: "chat:write")

    stored = Fd::StaffSlack.with_connection do |conn|
      conn.select_value("SELECT user_token FROM fd.staff_slack WHERE staff_user_id = 'UME'")
    end
    assert_no_match(/xoxp-real/, stored)
  end

  test "slack account callback with wrong state stores nothing and flashes mismatch" do
    sign_in_as(@me)
    start_linking

    stub_oauth(:exchange, granted) do
      get fd_slack_account_callback_path(code: "c0de", state: "somebody-elses")
    end

    assert_nil Fd::StaffSlack.active_for("UME")
    assert_match(/State mismatch/, flash[:alert])
  end

  test "slack account callback without started linking stores nothing and flashes mismatch" do
    sign_in_as(@me)
    get fd_slack_account_callback_path(code: "c0de", state: "made-up")

    assert_nil Fd::StaffSlack.active_for("UME")
    assert_match(/State mismatch/, flash[:alert])
  end

  test "slack account callback with other user id stores nothing and flashes mismatch" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    stub_oauth(:exchange, granted(id: "UOTHER")) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    assert_nil Fd::StaffSlack.active_for("UME")
    assert_match(/Account does not match the signed-in user/, flash[:alert])
  end

  test "slack account callback without chat:write scope stores nothing and flashes alert" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    stub_oauth(:exchange, granted(scope: "identity.basic")) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    assert_nil Fd::StaffSlack.active_for("UME")
    assert_match(/expected chat:write/, flash[:alert])
  end

  test "slack account callback with other team id and SLACK_TEAM_ID set stores nothing" do
    ENV["SLACK_TEAM_ID"] = "T0FIRE"
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    stub_oauth(:exchange, granted(team: "T0OTHER")) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    assert_nil Fd::StaffSlack.active_for("UME")
    assert_match(/different workspace/, flash[:alert])
  end

  test "slack account callback with access_denied error stores nothing and flashes cancelled" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
    get fd_slack_account_callback_path(error: "access_denied", state: state)

    assert_nil Fd::StaffSlack.active_for("UME")
    assert_match(/cancelled/, flash[:alert])
  end

  test "slack account callback with RefusedError stores nothing and flashes reason" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    refusal = ->(**) { raise Slack::Oauth::RefusedError, "invalid_code" }
    stub_oauth(:exchange, refusal) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    assert_nil Fd::StaffSlack.active_for("UME")
    assert_match(/invalid_code/, flash[:alert])
  end

  test "slack account destroy revokes token with slack and sets revoked_at and revoked_by" do
    sign_in_as(@me)
    row = Fd::StaffSlack.store!("UME", token: "xoxp-real", team_id: "T0FIRE",
      scopes: "chat:write")

    revoked_token = nil
    stub_oauth(:revoke_token, ->(token) { revoked_token = token }) do
      delete fd_slack_account_path
    end

    assert_equal "xoxp-real", revoked_token, "revoke_token called with the stored token"
    assert_nil Fd::StaffSlack.active_for("UME")
    assert_not_nil row.reload.revoked_at
    assert_equal "UME", row.revoked_by
    assert_equal 1, entries("unlinked").count
  end

  test "slack account destroy without linked account flashes alert and creates no entry" do
    sign_in_as(@me)
    delete fd_slack_account_path

    assert_match(/not linked/, flash[:alert])
    assert_equal 0, entries("unlinked").count
  end

  test "slack account callback after unlink reuses row and clears revoked_by" do
    sign_in_as(@me)
    Fd::StaffSlack.store!("UME", token: "old", team_id: "T0FIRE", scopes: "chat:write")
      .revoke_token!("UME")

    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
    stub_oauth(:exchange, granted) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    row = Fd::StaffSlack.active_for("UME")
    assert_not_nil row
    assert_equal "xoxp-real", row.user_token
    assert_nil row.revoked_by
    assert_equal 1, Fd::StaffSlack.count, "one row per staff user"
  end
end
