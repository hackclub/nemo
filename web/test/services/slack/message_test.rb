require "test_helper"

class Slack::MessageTest < ActiveSupport::TestCase
  CHANNEL_ID = "C1LOUNGE".freeze
  TS = "1790701062.123456".freeze

  MESSAGE = {
    "type" => "message", "ts" => TS, "user" => "U1", "text" => "big news",
    "blocks" => [{ "type" => "rich_text" }]
  }.freeze

  def with_memory_cache
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original_cache
  end

  def stub_slack(reply)
    original_call = Slack::ProxyClient.method(:call)
    calls = []
    Slack::ProxyClient.define_singleton_method(:call) do |method, params = {}, **options|
      calls << [method, params, options]
      reply.call(method, params)
    end
    yield calls
  ensure
    Slack::ProxyClient.define_singleton_method(:call, original_call)
  end

  def one_message = ->(*) { { "ok" => true, "messages" => [MESSAGE] } }

  test "at requests one message by ts with the admin credential" do
    with_memory_cache do
      stub_slack(one_message) do |calls|
        result = Slack::Message.at(CHANNEL_ID, TS)

        method, params, options = calls.sole
        assert_equal Slack::Message::METHOD, method
        assert_equal CHANNEL_ID, params["channel"]
        assert_equal TS, params["latest"]
        assert_equal TS, params["oldest"]
        assert params["inclusive"]
        assert_equal 1, params["limit"]
        assert_equal "admin", options[:credential]
        assert_equal "big news", result.message["text"]
        assert result.message?
      end
    end
  end

  test "at with a thread ts requests the reply from conversations.replies" do
    reply = MESSAGE.merge("ts" => "1790701099.000200", "thread_ts" => TS, "text" => "in the thread")
    with_memory_cache do
      stub_slack(->(*) { { "ok" => true, "messages" => [MESSAGE.merge("thread_ts" => TS), reply] } }) do |calls|
        result = Slack::Message.at(CHANNEL_ID, reply["ts"], thread_ts: TS)

        method, params, options = calls.sole
        assert_equal Slack::Message::REPLIES_METHOD, method
        assert_equal TS, params["ts"]
        assert_equal reply["ts"], params["latest"]
        assert_equal reply["ts"], params["oldest"]
        assert_equal "admin", options[:credential]
        assert_equal "in the thread", result.message["text"]
      end
    end
  end

  test "at with a thread ts equal to ts reads conversations.history" do
    with_memory_cache do
      stub_slack(one_message) do |calls|
        Slack::Message.at(CHANNEL_ID, TS, thread_ts: TS)

        assert_equal Slack::Message::METHOD, calls.sole.first
      end
    end
  end

  test "at does not call Slack again for a cached message" do
    with_memory_cache do
      stub_slack(one_message) do |calls|
        Slack::Message.at(CHANNEL_ID, TS)
        cached = Slack::Message.at(CHANNEL_ID, TS)

        assert_equal 1, calls.size, "the second lookup must be served from the cache"
        assert_equal "big news", cached.message["text"]
      end
    end
  end

  test "at returns :not_found when messages is empty" do
    with_memory_cache do
      stub_slack(->(*) { { "ok" => true, "messages" => [] } }) do
        result = Slack::Message.at(CHANNEL_ID, TS)

        assert_equal :not_found, result.error
        assert_not result.message?
      end
    end
  end

  test "at returns :not_found when the returned ts differs" do
    with_memory_cache do
      stub_slack(->(*) { { "ok" => true, "messages" => [MESSAGE.merge("ts" => "1790700000.000001")] } }) do
        assert_equal :not_found, Slack::Message.at(CHANNEL_ID, TS).error
      end
    end
  end

  test "at returns :not_found when the response has ok false" do
    with_memory_cache do
      stub_slack(->(*) { { "ok" => false, "error" => "channel_not_found" } }) do
        assert_equal :not_found, Slack::Message.at(CHANNEL_ID, TS).error
      end
    end
  end

  test "at returns :unavailable on UnavailableError" do
    with_memory_cache do
      stub_slack(->(*) { raise Slack::ProxyClient::UnavailableError, "proxy returned 503" }) do
        assert_equal :unavailable, Slack::Message.at(CHANNEL_ID, TS).error
      end
    end
  end

  test "at returns :reauth on AuthError" do
    with_memory_cache do
      stub_slack(->(*) { raise Slack::ProxyClient::AuthError, "invalid_auth" }) do
        assert_equal :reauth, Slack::Message.at(CHANNEL_ID, TS).error
      end
    end
  end

  test "at returns :not_configured on NotConfiguredError" do
    with_memory_cache do
      stub_slack(->(*) { raise Slack::ProxyClient::NotConfiguredError, "INTERNAL_PROXY_URL is not set" }) do
        assert_equal :not_configured, Slack::Message.at(CHANNEL_ID, TS).error
      end
    end
  end

  test "at does not cache an UnavailableError result" do
    with_memory_cache do
      attempts = 0
      stub_slack(lambda { |*|
        attempts += 1
        raise Slack::ProxyClient::UnavailableError, "proxy returned 503" if attempts == 1

        { "ok" => true, "messages" => [MESSAGE] }
      }) do
        assert_equal :unavailable, Slack::Message.at(CHANNEL_ID, TS).error
        assert_equal "big news", Slack::Message.at(CHANNEL_ID, TS).message["text"]
      end
    end
  end
end
