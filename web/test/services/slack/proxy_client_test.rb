require "test_helper"

class Slack::ProxyClientTest < ActiveSupport::TestCase
  setup do
    @url = ENV["INTERNAL_PROXY_URL"]
    @allow = ENV["PROXY_ALLOW_PLAINTEXT"]
    ENV["PROXY_ALLOW_PLAINTEXT"] = nil
  end

  teardown do
    ENV["INTERNAL_PROXY_URL"] = @url
    ENV["PROXY_ALLOW_PLAINTEXT"] = @allow
  end

  test "https to another machine is fine" do
    ENV["INTERNAL_PROXY_URL"] = "https://proxy.example.com"
    assert_equal "https://proxy.example.com", Slack::ProxyClient.base_url
  end

  test "plaintext to loopback is fine" do
    ENV["INTERNAL_PROXY_URL"] = "http://127.0.0.1:8002"
    assert_equal "http://127.0.0.1:8002", Slack::ProxyClient.base_url
  end

  test "plaintext to another machine is refused" do
    ENV["INTERNAL_PROXY_URL"] = "http://proxy.example.com:8002"
    err = assert_raises(Slack::ProxyClient::NotConfigured) { Slack::ProxyClient.base_url }
    assert_match "clear text", err.message
  end

  test "plaintext can be allowed on purpose" do
    ENV["INTERNAL_PROXY_URL"] = "http://proxy.example.com:8002"
    ENV["PROXY_ALLOW_PLAINTEXT"] = "true"
    assert_equal "http://proxy.example.com:8002", Slack::ProxyClient.base_url
  end
end
