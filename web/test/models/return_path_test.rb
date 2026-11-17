require "test_helper"

class ReturnPathTest < ActiveSupport::TestCase
  test "keeps local paths with query strings" do
    assert_equal "/engine?tab=faults", ReturnPath.sanitize("/engine?tab=faults")
    assert_equal "/fd/cases/12", ReturnPath.sanitize("/fd/cases/12")
    assert_equal "/", ReturnPath.sanitize("/")
  end

  test "rejects external and malformed targets" do
    [
      nil,
      "",
      "engine",
      "//evil.example/x",
      "https://evil.example/x",
      "/\\evil.example",
      "/a\\b",
      "javascript:alert(1)",
      "/ok\r\nLocation: https://evil.example",
      "/ok\u0000",
      "/#{'a' * ReturnPath::LIMIT}",
      ["/engine"]
    ].each do |value|
      assert_nil ReturnPath.sanitize(value), value.inspect
    end
  end

  test "rejects authentication paths" do
    ["/login", "/login?x=1", "/login/", "/auth/hackclub/callback", "/auth/failure", "/logout", "/dev/be/U1"].each do |value|
      assert_nil ReturnPath.sanitize(value), value
    end
  end
end
