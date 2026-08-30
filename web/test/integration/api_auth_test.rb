require "test_helper"

class ApiAuthTest < ActionDispatch::IntegrationTest
  setup do
    Fd::Flag.set!(:public_api, true, by: "UBOSS")
    @token, @secret = Api::Token.mint!("UOWNER1", "Toolbox")
  end

  teardown do
    Fd::Flag.delete_all
    Current.forget_flags
  end

  def ask(key = @secret, path: api_v1_token_path)
    get path, headers: key ? { "Authorization" => "Bearer #{key}" } : {}
  end

  def body
    JSON.parse(response.body)
  end

  test "a live key is told who it is, and never what it is" do
    ask

    assert_response :success
    assert_equal ["Toolbox", "UOWNER1", 100], body.values_at("name", "owner_user_id",
      "rate_per_minute")
    assert_equal @token.prefix, body["prefix"]
    assert_no_match(/#{@secret}/, response.body, "the key itself must never come back")
  end

  test "no header at all is an invalid token, not a crash" do
    ask(nil)

    assert_response :unauthorized
    assert_equal "invalid_token", body["error"]
  end

  test "a key nobody minted is refused" do
    ask("nemo_live_neverissuedatall12")

    assert_response :unauthorized
    assert_equal "invalid_token", body["error"]
  end

  test "a header that is not a bearer is refused" do
    get api_v1_token_path, headers: { "Authorization" => "Basic #{@secret}" }

    assert_response :unauthorized
    assert_equal "invalid_token", body["error"]
  end

  test "a revoked key says so, so a caller stops retrying" do
    @token.revoke!(by: "UOWNER1")
    ask

    assert_response :unauthorized
    assert_equal "revoked_token", body["error"]
  end

  test "the whole api is shut while the flag is off, even with a good key" do
    Fd::Flag.set!(:public_api, false, by: "UBOSS")
    ask

    assert_response :service_unavailable
    assert_equal "api_off", body["error"]
  end

  test "using a key stamps it, and does not stamp it again on every call" do
    assert_nil @token.last_used_at

    ask
    first = @token.reload.last_used_at
    assert_not_nil first

    ask
    assert_equal first, @token.reload.last_used_at, "one write a minute, not one a request"
  end

  test "a signed in browser session opens nothing on the api" do
    staff = Staff.create!(user_id: "UBOSS2", community_manager: true)
    sign_in_as(staff)

    get api_v1_token_path

    assert_response :unauthorized
    assert_equal "invalid_token", body["error"]
  end

  test "every refusal answers in json, never a redirect or a page" do
    Fd::Flag.set!(:public_api, false, by: "UBOSS")
    ask(nil)

    assert_equal "application/json", response.media_type
    assert body.key?("message"), "a caller is told what to do about it"
  end
end
