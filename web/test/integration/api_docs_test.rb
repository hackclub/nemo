require "test_helper"

class ApiDocsTest < ActionDispatch::IntegrationTest
  setup do
    @member = Staff.create!(user_id: "UMEMBER3")
  end

  test "any signed in member can read the docs, role or no role" do
    sign_in_as(@member)
    get docs_path

    assert_response :success
    assert_select ".docs-sec", Docs.section_ids.size
    assert_select ".rail-item[href=?]", docs_path
  end

  test "signed out, the docs ask you to sign in" do
    get docs_path

    assert_redirected_to login_path
  end

  test "the rate it quotes is the one actually in force" do
    Api::Setting.set!("rate_per_minute", 45, by: "UBOSS")
    sign_in_as(@member)
    get docs_path

    assert_select ".docs-meta dd", text: "45/min per key"
    assert_select ".pre", text: /RateLimit-Limit: 45/
  end

  test "every error the api can return is written down, and nothing else" do
    sign_in_as(@member)
    get docs_path

    listed = css_select("#errors .data-table tbody td:nth-child(2)").map(&:text)
    assert_equal Api::V1::BaseController::CALLER_ERRORS.map { |_status, key, _said| key }.sort,
      listed.sort
  end

  test "the contents and the page cannot drift apart" do
    sign_in_as(@member)
    get docs_path

    listed = css_select(".docs-nav a").map { |link| link["href"].delete_prefix("#") }
    rendered = css_select(".docs-sec").map { |sec| sec["id"] }

    assert_equal Docs.section_ids, listed, "the contents list every section, in order"
    assert_equal Docs.section_ids, rendered, "and every one of them is on the page"
  end

  test "a topic names its sections once, so a duplicate anchor cannot creep in" do
    assert_equal Docs.section_ids.uniq, Docs.section_ids
  end

  test "the docs never name a key somebody actually holds" do
    sign_in_as(@member)
    _token, secret = Api::Token.mint!(@member.user_id, "Toolbox")
    get docs_path

    assert_no_match(/#{Regexp.escape(secret)}/, response.body,
      "a real key must not leak into the examples")
    assert_match(/nemo_live_7Fj2/, response.body, "the example key is a made up one")
  end
end
