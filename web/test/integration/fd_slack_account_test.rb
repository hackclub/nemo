require "test_helper"

class FdSlackAccountTest < ActionDispatch::IntegrationTest
  def instead_of(name, answer)
    original = Slack::Oauth.method(name)
    Slack::Oauth.define_singleton_method(name) do |*args, **kwargs|
      answer.respond_to?(:call) ? answer.call(*args, **kwargs) : answer
    end
    yield
  ensure
    Slack::Oauth.define_singleton_method(name, original)
  end

  KEPT = %w[NEMO_CLIENT_ID NEMO_CLIENT_SECRET SLACK_TEAM_ID].freeze

  setup do
    @me = hold_role!("UME", "community_manager")
    @was = ENV.slice(*KEPT)
    KEPT.each { |name| ENV.delete(name) }
    ENV["NEMO_CLIENT_ID"] = "1.2"
    ENV["NEMO_CLIENT_SECRET"] = "shh"
  end

  teardown do
    KEPT.each { |name| ENV.delete(name) }
    @was.each { |name, value| ENV[name] = value }
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

  test "a signed out visitor cannot start linking" do
    start_linking
    assert_redirected_to login_path
  end

  test "starting sends you to slack with the user scope and a state" do
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
    assert query["state"].present?, "a state must be sent so the callback can be checked"
  end

  test "starting refuses when the app is not configured" do
    ENV.delete("NEMO_CLIENT_ID")
    sign_in_as(@me)
    start_linking

    assert_redirected_to account_path
    assert_match(/not set up/, flash[:alert])
  end

  test "a callback that matches keeps the token and writes the trail" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    instead_of(:exchange, granted) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    row = Fd::StaffSlack.held_by("UME")
    assert_not_nil row
    assert_equal "xoxp-real", row.user_token
    assert_equal "T0FIRE", row.team_id
    assert_equal "chat:write", row.scopes
    assert_equal 1, entries("linked").count
    assert_no_match(/xoxp-real/, entries("linked").sole.after.to_json)
  end

  test "the token is not readable straight from the column" do
    sign_in_as(@me)
    Fd::StaffSlack.keep!("UME", token: "xoxp-real", team_id: "T0FIRE", scopes: "chat:write")

    stored = Fd::StaffSlack.with_connection do |conn|
      conn.select_value("SELECT user_token FROM fd.staff_slack WHERE staff_user_id = 'UME'")
    end
    assert_no_match(/xoxp-real/, stored)
  end

  test "a callback with the wrong state keeps nothing" do
    sign_in_as(@me)
    start_linking

    instead_of(:exchange, granted) do
      get fd_slack_account_callback_path(code: "c0de", state: "somebody-elses")
    end

    assert_nil Fd::StaffSlack.held_by("UME")
    assert_match(/did not match this browser/, flash[:alert])
  end

  test "a callback with no state at all keeps nothing" do
    sign_in_as(@me)
    get fd_slack_account_callback_path(code: "c0de", state: "made-up")

    assert_nil Fd::StaffSlack.held_by("UME")
    assert_match(/did not match this browser/, flash[:alert])
  end

  test "somebody else's slack account is refused" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    instead_of(:exchange, granted(id: "UOTHER")) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    assert_nil Fd::StaffSlack.held_by("UME")
    assert_match(/not the account you are signed in as/, flash[:alert])
  end

  test "a grant without the scope we asked for is refused" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    instead_of(:exchange, granted(scope: "identity.basic")) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    assert_nil Fd::StaffSlack.held_by("UME")
    assert_match(/not chat:write/, flash[:alert])
  end

  test "a grant from another workspace is refused when the workspace is pinned" do
    ENV["SLACK_TEAM_ID"] = "T0FIRE"
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    instead_of(:exchange, granted(team: "T0OTHER")) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    assert_nil Fd::StaffSlack.held_by("UME")
    assert_match(/different workspace/, flash[:alert])
  end

  test "a cancelled grant says so and keeps nothing" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
    get fd_slack_account_callback_path(error: "access_denied", state: state)

    assert_nil Fd::StaffSlack.held_by("UME")
    assert_match(/cancelled/, flash[:alert])
  end

  test "slack refusing the exchange is reported, not raised" do
    sign_in_as(@me)
    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    refusal = ->(**) { raise Slack::Oauth::Refused, "invalid_code" }
    instead_of(:exchange, refusal) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    assert_nil Fd::StaffSlack.held_by("UME")
    assert_match(/invalid_code/, flash[:alert])
  end

  test "unlinking gives the token back to slack and marks the row" do
    sign_in_as(@me)
    row = Fd::StaffSlack.keep!("UME", token: "xoxp-real", team_id: "T0FIRE",
      scopes: "chat:write")

    told = nil
    instead_of(:give_back, ->(token) { told = token }) do
      delete fd_slack_account_path
    end

    assert_equal "xoxp-real", told, "slack must be told to forget the token"
    assert_nil Fd::StaffSlack.held_by("UME")
    assert_not_nil row.reload.revoked_at
    assert_equal "UME", row.revoked_by
    assert_equal 1, entries("unlinked").count
  end

  test "unlinking what was never linked is refused" do
    sign_in_as(@me)
    delete fd_slack_account_path

    assert_match(/not linked/, flash[:alert])
    assert_equal 0, entries("unlinked").count
  end

  test "linking again after unlinking brings the row back to life" do
    sign_in_as(@me)
    Fd::StaffSlack.keep!("UME", token: "old", team_id: "T0FIRE", scopes: "chat:write")
      .give_back!("UME")

    start_linking
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
    instead_of(:exchange, granted) do
      get fd_slack_account_callback_path(code: "c0de", state: state)
    end

    row = Fd::StaffSlack.held_by("UME")
    assert_not_nil row
    assert_equal "xoxp-real", row.user_token
    assert_nil row.revoked_by
    assert_equal 1, Fd::StaffSlack.count, "one row per person, not one per attempt"
  end
end
