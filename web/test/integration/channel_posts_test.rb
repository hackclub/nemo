require "test_helper"

class ChannelPostsTest < ActionDispatch::IntegrationTest
  SAID = {
    "ts" => nil, "text" => "big news <@UMENTION>",
    "blocks" => [{ "type" => "rich_text", "elements" => [
      { "type" => "rich_text_section", "elements" => [
        { "type" => "text", "text" => "big news " },
        { "type" => "user", "user_id" => "UMENTION" }
      ] }
    ] }]
  }.freeze

  RANGE = { "start_date" => "2026-01-01", "end_date" => "2026-12-31" }.freeze
  NO_ANALYTICS = { "channel_analytics" => [] }.freeze

  setup do
    @post = Analytics::FctMessage.where(is_reply: false, subtype: nil)
      .where.not(author_id: nil).where("author_id ~ '^[UW]'").order(posted_at: :desc).first
    skip "the tiny seed holds no top-level post" if @post.nil?

    @me = hold_role!(@post.author_id, "analytics")
    sign_in_as(@me)
    Rails.cache.clear
  end

  teardown do
    Channels::Activity::Setting.where(channel_id: @post&.channel_id).delete_all
  end

  def shown!
    Channels::Activity::Setting.create!(channel_id: @post.channel_id, set_by: "test",
      set_at: Time.current)
  end

  def answering(reply)
    was = Slack::ProxyClient.method(:call)
    asked = []
    Slack::ProxyClient.define_singleton_method(:call) do |method, params = {}, **|
      next RANGE if method == "admin.analytics.getAvailableDateRange"
      next NO_ANALYTICS if method == "admin.analytics.getChannelAnalytics"

      asked << [method, params]
      reply.call(method, params)
    end
    yield asked
  ensure
    Slack::ProxyClient.define_singleton_method(:call, was)
  end

  def one_post
    ->(_method, params) { { "ok" => true, "messages" => [SAID.merge("ts" => params["latest"])] } }
  end

  def ask(**params) = get channel_path(@post.channel_id, **params)

  test "a channel that does not show activity has no posts tab" do
    answering(->(*) { flunk "slack was asked without the tab" }) do
      ask

      assert_response :success
      assert_no_match(/view=posts/, response.body)
    end
  end

  test "asking for the tab anyway falls back rather than erroring" do
    answering(->(*) { flunk "slack was asked without the tab" }) do
      ask(view: "posts")

      assert_response :success
      assert_match(/aria-current="true"[^>]*>\s*Overview|Overview\s*<\/a>/, response.body)
      assert_no_match(/You have not posted here/, response.body)
    end
  end

  test "a channel that shows activity has the tab" do
    shown!
    answering(one_post) { ask }

    assert_response :success
    assert_match(/view=posts/, response.body)
  end

  test "the tab shows what the post said, read back from slack" do
    shown!
    answering(one_post) do |asked|
      ask(view: "posts")

      assert_response :success
      assert_match(/big news/, response.body)
      assert_equal ["conversations.history"], asked.map(&:first).uniq
      assert_operator asked.size, :<=, Channels::Posts::SHOWN
      assert_operator asked.size, :>=, 1
    end
  end

  test "no expand than three posts, with a word about older ones" do
    shown!
    answering(one_post) do |asked|
      ask(view: "posts")

      assert_operator asked.size, :<=, 3
      assert_match(/View message activity/, response.body)
    end
  end

  test "each post opens its own activity page" do
    shown!
    answering(one_post) do
      ask(view: "posts")

      assert_match(/href="\/messages\/#{@post.channel_id}\/#{Regexp.escape(@post.ts)}"/,
        response.body)
    end
  end

  test "somebody else's posts are never listed" do
    shown!
    other = Analytics::FctMessage.where(channel_id: @post.channel_id, is_reply: false)
      .where.not(author_id: [@post.author_id, nil]).where("author_id ~ '^[UW]'").first
    skip "the seed has nobody else in this channel" if other.nil?

    answering(one_post) do |asked|
      ask(view: "posts")

      assert_no_match(/#{Regexp.escape(other.ts)}/, response.body)
      assert asked.none? { |_, params| params["latest"] == other.ts }
    end
  end

  test "a post slack will not answer for leaves the page standing" do
    shown!
    answering(->(*) { raise Slack::ProxyClient::UnavailableError, "proxy returned 503" }) do
      ask(view: "posts")

      assert_response :success
      assert_match(/would not answer/, response.body)
    end
  end
end
