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

  def batch(user_ids, on: @channel)
    post api_v1_channel_managers_check_path(channel_id: on),
      params: { user_ids: user_ids }.to_json,
      headers: head.merge("Content-Type" => "application/json")
  end

  def body = JSON.parse(response.body)

  test "an opted in manager is answered yes, with when and how fresh" do
    opted_in(MANAGER)
    ask(MANAGER)

    assert_response :success
    assert_equal [@channel, MANAGER, "granted", true], body.values_at("channel_id", "user_id",
      "consent", "is_manager")
    assert_not body["stale"]
    assert body["synced_at"].present?
    assert body["since"].present?
  end

  test "an opted in bystander is answered no, and carries no since" do
    opted_in(BYSTANDER)
    ask(BYSTANDER)

    assert_response :success
    assert_equal ["granted", false], body.values_at("consent", "is_manager")
    assert_not body.key?("since")
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

  test "a channel we do not hold is not found, before consent is even looked at" do
    opted_in(MANAGER)
    ask(MANAGER, on: "CDOESNOTEXIST")

    assert_response :not_found
    assert_equal "channel_not_found", body["error"]
    assert_empty Api::RequestLog.all, "a 404 is not an ask about anybody"
  end

  test "a malformed id is refused before anything is read" do
    ask("nope")
    assert_response :unprocessable_content
    assert_equal "bad_user_id", body["error"]

    ask(MANAGER, on: "nope")
    assert_response :unprocessable_content
    assert_equal "bad_channel_id", body["error"]
  end

  test "every ask is written down, with what it was told" do
    opted_in(MANAGER)
    ask(MANAGER)
    ask(BYSTANDER)

    logged = Api::RequestLog.order(:id).pluck(:subject_user_id, :outcome, :channel_id)
    assert_equal [[MANAGER, "manager", @channel], [BYSTANDER, "withheld", @channel]], logged
    assert_equal [@token.id], Api::RequestLog.distinct.pluck(:token_id)
  end

  test "a batch answers each subject and costs one row each" do
    opted_in(MANAGER)
    batch([MANAGER, BYSTANDER])

    assert_response :success
    assert_equal @channel, body["channel_id"]
    assert_equal [MANAGER, BYSTANDER], body["results"].map { _1["user_id"] }
    assert_equal [true, nil], body["results"].map { _1["is_manager"] }
    assert_equal 2, Api::RequestLog.count
  end

  test "a batch over the cap is refused and says what the cap is" do
    batch(Array.new(101) { |i| format("U%010d", i) })

    assert_response :unprocessable_content
    assert_equal "too_many_subjects", body["error"]
    assert_equal 100, body["most"]
    assert_empty Api::RequestLog.all
  end

  test "one bad id spoils the batch rather than being quietly dropped" do
    batch([MANAGER, "nope"])

    assert_response :unprocessable_content
    assert_equal "bad_user_id", body["error"]
  end

  test "a batch nobody consented to reads nothing about the channel" do
    asked = []
    was = ChannelManagers.method(:freshen)
    ChannelManagers.define_singleton_method(:freshen) { |id| asked << id }
    batch([MANAGER, BYSTANDER])

    assert_empty asked, "a wholly withheld batch must not touch slack"
    assert_equal 2, Api::RequestLog.where(outcome: "withheld").count
  ensure
    ChannelManagers.define_singleton_method(:freshen, was)
  end

  test "the api still needs a token for a check" do
    get api_v1_channel_manager_path(channel_id: @channel, user_id: MANAGER)

    assert_response :unauthorized
    assert_empty Api::RequestLog.all
  end
end
