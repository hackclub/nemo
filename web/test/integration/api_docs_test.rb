require "test_helper"

class ApiDocsTest < ActionDispatch::IntegrationTest
  setup do
    @member = Account.create!(user_id: "UMEMBER3")
    @topic = Docs::CHANNEL_MANAGERS
  end

  test "the docs index sends you to the first topic" do
    sign_in_as(@member)
    get docs_path

    assert_redirected_to doc_path(@topic.slug)
  end

  test "any signed in member can read a topic, role or no role" do
    sign_in_as(@member)
    get doc_path(@topic.slug)

    assert_response :success
    assert_select ".doc-sec", @topic.sections.size
  end

  test "a topic nobody wrote falls back rather than raising" do
    sign_in_as(@member)
    get doc_path("wingspan")

    assert_redirected_to docs_path
  end

  test "signed out, the docs ask you to sign in" do
    get docs_path

    assert_redirected_to login_path
  end

  test "the rate it quotes is the one actually in force" do
    Api::Setting.set!("rate_per_minute", 45, by: "UBOSS")
    sign_in_as(@member)
    get doc_path(@topic.slug)

    assert_select ".doc-spec dd", text: "45/min"
    assert_select ".pre", text: /RateLimit-Limit: 45/
  end

  test "every error the api can return is written down, and nothing else" do
    sign_in_as(@member)
    get doc_path(@topic.slug)

    listed = css_select("#errors .doc-def > dt").map { |dt| dt.text.split.first }
    assert_equal Api::V1::BaseController::CALLER_ERRORS.map { |_status, key, _said| key }.sort,
      listed.sort
  end

  test "the sidebar and the page cannot drift apart" do
    sign_in_as(@member)
    get doc_path(@topic.slug)

    listed = css_select("#section-nav .cnav-sub a").map { |link| link["href"].delete_prefix("#") }
    rendered = css_select(".doc-sec").map { |sec| sec["id"] }

    assert_equal @topic.sections.map(&:id), listed, "the sidebar lists every section, in order"
    assert_equal @topic.sections.map(&:id), rendered, "and every one of them is on the page"
  end

  test "the sidebar lists every topic, and marks the one being read" do
    sign_in_as(@member)
    get doc_path(@topic.slug)

    assert_select "#section-nav .cnav-group a[href=?]", doc_path(@topic.slug)
    assert_select "#section-nav a[aria-current=page]", 1
  end

  test "a topic names its sections once, so a duplicate anchor cannot creep in" do
    assert_equal Docs.section_ids.uniq, Docs.section_ids
  end

  test "every topic has a partial to render, so adding one cannot half land" do
    Docs.topics.each do |topic|
      assert File.exist?(Rails.root.join("app/views/docs/_#{topic.slug.tr('-', '_')}.html.erb")),
        "#{topic.slug} has no partial"
    end
  end

  test "the docs never name a key somebody actually holds" do
    sign_in_as(@member)
    app = make_app!(@member.user_id)
    _token, secret = Api::Token.mint!(app, "Toolbox")
    get doc_path(@topic.slug)

    assert_no_match(/#{Regexp.escape(secret)}/, response.body,
      "a real key must not leak into the examples")
    assert_match(/nemo_live_7Fj2/, response.body, "the example key is a made up one")
  end
end
