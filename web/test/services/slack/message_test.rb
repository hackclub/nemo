require "test_helper"

class Slack::MessageTest < ActiveSupport::TestCase
  ROOM = "C1LOUNGE".freeze
  TS = "1790701062.123456".freeze

  SAID = {
    "type" => "message", "ts" => TS, "user" => "U1", "text" => "big news",
    "blocks" => [{ "type" => "rich_text" }]
  }.freeze

  def caching
    was = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = was
  end

  def answering(reply)
    was = Slack::ProxyClient.method(:call)
    asked = []
    Slack::ProxyClient.define_singleton_method(:call) do |method, params = {}, **rest|
      asked << [method, params, rest]
      reply.call(method, params)
    end
    yield asked
  ensure
    Slack::ProxyClient.define_singleton_method(:call, was)
  end

  def one_message = ->(*) { { "ok" => true, "messages" => [SAID] } }

  test "a post is asked for by the one timestamp, on the admin credential" do
    caching do
      answering(one_message) do |asked|
        found = Slack::Message.at(ROOM, TS)

        method, params, rest = asked.sole
        assert_equal Slack::Message::METHOD, method
        assert_equal ROOM, params["channel"]
        assert_equal TS, params["latest"]
        assert_equal TS, params["oldest"]
        assert params["inclusive"]
        assert_equal 1, params["limit"]
        assert_equal "admin", rest[:credential]
        assert_equal "big news", found.message["text"]
        assert found.found?
      end
    end
  end

  test "a second look at the same post does not ask slack again" do
    caching do
      answering(one_message) do |asked|
        Slack::Message.at(ROOM, TS)
        again = Slack::Message.at(ROOM, TS)

        assert_equal 1, asked.size, "the second look must come from the cache"
        assert_equal "big news", again.message["text"]
      end
    end
  end

  test "a post slack no longer has reads as not found" do
    caching do
      answering(->(*) { { "ok" => true, "messages" => [] } }) do
        found = Slack::Message.at(ROOM, TS)

        assert_equal :not_found, found.error
        assert_not found.found?
      end
    end
  end

  test "a neighbour slack hands back instead is not taken for the post" do
    caching do
      answering(->(*) { { "ok" => true, "messages" => [SAID.merge("ts" => "1790700000.000001")] } }) do
        assert_equal :not_found, Slack::Message.at(ROOM, TS).error
      end
    end
  end

  test "ok false is not mistaken for a post" do
    caching do
      answering(->(*) { { "ok" => false, "error" => "channel_not_found" } }) do
        assert_equal :not_found, Slack::Message.at(ROOM, TS).error
      end
    end
  end

  test "a proxy that is down leaves the page standing" do
    caching do
      answering(->(*) { raise Slack::ProxyClient::UnavailableError, "proxy returned 503" }) do
        assert_equal :unavailable, Slack::Message.at(ROOM, TS).error
      end
    end
  end

  test "a session that needs refreshing says so" do
    caching do
      answering(->(*) { raise Slack::ProxyClient::AuthError, "invalid_auth" }) do
        assert_equal :reauth, Slack::Message.at(ROOM, TS).error
      end
    end
  end

  test "a proxy that is not set up says so" do
    caching do
      answering(->(*) { raise Slack::ProxyClient::NotConfiguredError, "INTERNAL_PROXY_URL is not set" }) do
        assert_equal :not_configured, Slack::Message.at(ROOM, TS).error
      end
    end
  end

  test "a failure is never cached, so a blip does not sticky for ten minutes" do
    caching do
      tries = 0
      answering(lambda { |*|
        tries += 1
        raise Slack::ProxyClient::UnavailableError, "proxy returned 503" if tries == 1

        { "ok" => true, "messages" => [SAID] }
      }) do
        assert_equal :unavailable, Slack::Message.at(ROOM, TS).error
        assert_equal "big news", Slack::Message.at(ROOM, TS).message["text"]
      end
    end
  end
end
