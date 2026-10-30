require "test_helper"

class ApiDocsTest < ActionDispatch::IntegrationTest
  setup do
    @member = Account.create!(user_id: "UMEMBER3")
    @topic = Docs::CHANNEL_MANAGERS
  end

  test "docs index redirects to the first topic" do
    sign_in_as(@member)
    get docs_path

    assert_redirected_to doc_path(@topic.slug)
  end

  test "docs topic renders every section for a member without a role" do
    sign_in_as(@member)
    get doc_path(@topic.slug)

    assert_response :success
    assert_select ".doc-sec", @topic.sections.size
  end

  test "docs unknown topic redirects to the docs index" do
    sign_in_as(@member)
    get doc_path("wingspan")

    assert_redirected_to docs_path
  end

  test "docs index signed out redirects to login" do
    get docs_path

    assert_redirected_to login_path
  end

  test "docs topic shows the current rate_per_minute setting" do
    Api::Setting.set!("rate_per_minute", 45, by: "UBOSS")
    sign_in_as(@member)
    get doc_path(@topic.slug)

    assert_select ".doc-spec dd", text: "45/min"
    assert_select ".pre", text: /RateLimit-Limit: 45/
  end

  test "docs errors section lists exactly the CALLER_ERRORS keys" do
    sign_in_as(@member)
    get doc_path(@topic.slug)

    listed = css_select("#errors .doc-def > dt").map { |dt| dt.text.split.first }
    assert_equal Api::V1::BaseController::CALLER_ERRORS.map { |_status, key, _message| key }.sort,
      listed.sort
  end

  test "docs section nav lists the same section ids as the page" do
    sign_in_as(@member)
    get doc_path(@topic.slug)

    listed = css_select("#section-nav .community-nav-sub a").map { |link| link["href"].delete_prefix("#") }
    rendered = css_select(".doc-sec").map { |sec| sec["id"] }

    assert_equal @topic.sections.map(&:id), listed, "the sidebar lists every section, in order"
    assert_equal @topic.sections.map(&:id), rendered, "page renders every section"
  end

  test "docs nav links the current topic and has one aria-current link" do
    sign_in_as(@member)
    get doc_path(@topic.slug)

    assert_select "#section-nav .community-nav-group a[href=?]", doc_path(@topic.slug)
    assert_select "#section-nav .community-nav-group a[aria-current=page]", 1
  end

  test "Docs.section_ids has no duplicates" do
    assert_equal Docs.section_ids.uniq, Docs.section_ids
  end

  test "every Docs topic has a view partial" do
    Docs.topics.each do |topic|
      assert File.exist?(Rails.root.join("app/views/docs/_#{topic.slug.tr('-', '_')}.html.erb")),
        "#{topic.slug} has no partial"
    end
  end

  test "docs topic does not include an issued token secret" do
    sign_in_as(@member)
    app = make_app!(@member.user_id)
    _token, secret = Api::Token.mint!(app, "Toolbox")
    get doc_path(@topic.slug)

    assert_no_match(/#{Regexp.escape(secret)}/, response.body,
      "a real key must not leak into the examples")
    assert_match(/nemo_live_7Fj2/, response.body, "example key is a placeholder")
  end
end
