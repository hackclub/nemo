require "test_helper"

class CspTest < ActionDispatch::IntegrationTest
  def img_src
    get root_path
    response.headers["Content-Security-Policy"].to_s[/img-src ([^;]*)/, 1].to_s.split
  end

  test "the emoji cdn is allowed, not only the avatar one" do
    assert_includes img_src, "https://*.slack-edge.com"
  end

  test "cachet is still allowed for faces" do
    assert_includes img_src, "https://cachet.hackclub.com"
  end
end
