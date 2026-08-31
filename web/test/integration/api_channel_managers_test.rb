require "test_helper"

class ApiChannelManagersTest < ActionDispatch::IntegrationTest
  MANAGER = "U0BGRUHPTTR".freeze
  BYSTANDER = "U04KX9TQ2AA".freeze

  setup do
    Fd::Flag.set!(:public_api, true, by: "UBOSS")
    @token, @secret = Api::Token.mint!("UOWNER1", "Toolbox")
    @channel = Analytics::DimChannel.first.channel_id
    Api::ChannelManager.delete_all
    Api::ChannelSweep.delete_all
    Api::RequestLog.delete_all
    Api::Consent.delete_all
    manages(MANAGER)
  end

  teardown do
    Fd::Flag.delete_all
    Current.forget_flags
  end

  def manages(user_id, on: @channel)
    Api::ChannelManager.create!(channel_id: on, user_id: user_id, assigned_at: 1.year.ago)
    Api::ChannelSweep.stamp!(on, 1)
  end

  def opted_in(user_id)
    Api::Consent.set!(user_id, "channel_manager", true, via: "dashboard")
  end

  def head(key = @secret)
    { "Authorization" => "Bearer #{key}" }
  end

  def ask(user_id, on: @channel)
    get api_v1_channel_manager_path(channel_id: on, user_id: user_id), headers: head
  end

  def body = JSON.parse(response.body)

  def body_of
    yield
    body
  end

  test "an opted in manager is answered yes, with when and how fresh" do
    opted_in(MANAGER)
    ask(MANAGER)

    assert_response :success
    assert_equal [@channel, MANAGER, "granted", true], body.values_at("channel_id", "user_id",
      "consent", "is_manager")
    assert_not body["stale"]
    assert body["synced_at"].present?
    assert_not body.key?("since"), "when somebody became a manager is not the caller's business"
  end

  test "an opted in bystander is answered no" do
    opted_in(BYSTANDER)
    ask(BYSTANDER)

    assert_response :success
    assert_equal ["granted", false], body.values_at("consent", "is_manager")
  end

  test "somebody who never opted in is withheld, and told nothing else" do
    ask(MANAGER)

    assert_response :success
    assert_equal "withheld", body["consent"]
    assert_nil body["is_manager"]
    assert_match(%r{/you/api\z}, body["opt_in_url"])
  end

  test "withheld looks the same whether or not they manage it" do
    ask(MANAGER)
    managing = body

    ask(BYSTANDER)

    assert_equal managing.except("user_id"), body.except("user_id"),
      "the shape must not leak the answer it is withholding"
  end

  test "a withheld ask never carries freshness, because nothing was read" do
    ask(MANAGER)

    assert_not body.key?("synced_at")
    assert_not body.key?("stale")
  end

  test "a private channel is answered like any other, because the member opted in" do
    opted_in(MANAGER)
    manages(MANAGER, on: "C0PRIVATE99")
    ask(MANAGER, on: "C0PRIVATE99")

    assert_response :success
    assert_equal ["granted", true], body.values_at("consent", "is_manager")
  end

  test "a channel we hold nothing on answers no, not whether it exists" do
    opted_in(MANAGER)
    ask(MANAGER, on: "C0NOTHINGHERE")

    assert_response :success
    assert_equal ["granted", false], body.values_at("consent", "is_manager")
  end

  test "consent is settled before the channel, so an opted out ask reveals no channel" do
    real = body_of { ask(MANAGER, on: @channel) }
    made_up = body_of { ask(MANAGER, on: "C0NOSUCHTHING") }

    assert_equal "withheld", real["consent"]
    assert_equal real.except("channel_id"), made_up.except("channel_id"),
      "a private or unknown channel must look the same while consent is withheld"
  end

  test "a malformed id is refused before anything is read" do
    ask("nope")
    assert_response :unprocessable_content
    assert_equal "bad_user_id", body["error"]

    ask(MANAGER, on: "nope")
    assert_response :unprocessable_content
    assert_equal "bad_channel_id", body["error"]
    assert_empty Api::RequestLog.all, "a malformed id is not an ask about anybody"
  end

  test "every ask is written down, with what it was told" do
    opted_in(MANAGER)
    ask(MANAGER)
    ask(BYSTANDER)

    logged = Api::RequestLog.order(:id).pluck(:subject_user_id, :outcome, :channel_id)
    assert_equal [[MANAGER, "manager", @channel], [BYSTANDER, "withheld", @channel]], logged
    assert_equal [@token.id], Api::RequestLog.distinct.pluck(:token_id)
  end

  test "a withheld ask reads nothing about the channel" do
    asked = []
    was = ChannelManagers.method(:freshen)
    ChannelManagers.define_singleton_method(:freshen) { |id| asked << id }
    ask(MANAGER)

    assert_empty asked, "consent is checked before slack is ever troubled"
    assert_equal 1, Api::RequestLog.where(outcome: "withheld").count
  ensure
    ChannelManagers.define_singleton_method(:freshen, was)
  end

  test "the api still needs a token for a check" do
    get api_v1_channel_manager_path(channel_id: @channel, user_id: MANAGER)

    assert_response :unauthorized
    assert_empty Api::RequestLog.all
  end
end
