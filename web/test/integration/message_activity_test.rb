require "test_helper"

class MessageActivityTest < ActionDispatch::IntegrationTest
  STATS = {
    "ok" => true,
    "stats" => {
      "num_users_viewed" => 224, "num_users_clicked" => 58, "num_users_reacted" => 12,
      "num_shares" => 0, "top_threaded_reply_by_reactions_ts" => "1790701348.867479",
      "viewers_time_series" => { "data" => [
        { "seriesType" => "1h", "series" => [
          { "value" => 1_790_701_062_000_000, "count" => 0 },
          { "value" => 1_790_701_122_000_000, "count" => 3 }
        ] },
        { "seriesType" => "1d", "series" => [
          { "value" => 1_790_701_062_000_000, "count" => 0 },
          { "value" => 1_790_701_962_000_000, "count" => 23 },
          { "value" => 1_790_702_862_000_000, "count" => 14 }
        ] }
      ] },
      "client_breakdown" => { "desktop_count" => 75, "browser_count" => 123, "mobile_count" => 26 }
    }
  }.freeze

  setup do
    @post = Analytics::FctMessage.where(is_reply: false).where.not(author_id: nil)
      .where("author_id ~ '^[UW]'").order(:posted_at).first
    skip "the tiny seed holds no top-level post" if @post.nil?
    @author = Account.find_or_create_by!(user_id: @post.author_id)
    @path = message_activity_path(@post.channel_id, @post.ts)
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
      asked << [method, params]
      reply.call(method, params)
    end
    yield asked
  ensure
    Slack::ProxyClient.define_singleton_method(:call, was)
  end

  test "the author sees how their own post did" do
    shown!
    sign_in_as(@author)

    answering(->(*) { STATS }) do |asked|
      get @path

      assert_response :success
      assert_includes asked,
        ["insights.messageStats", { "channel" => @post.channel_id, "ts" => @post.ts }]
      assert_includes asked.map(&:first), "conversations.history"
    end
    assert_includes response.body, "224"
    assert_includes response.body, "Reach over time"
    assert_includes response.body, "new viewers"
    assert_includes response.body, "browser"
  end

  test "a span can be picked" do
    shown!
    sign_in_as(@author)

    answering(->(*) { STATS }) do
      get "#{@path}?span=1h"
    end

    assert_response :success
    assert_match(/aria-current="true"[^>]*>First hour|First hour<\/a>/, response.body)
  end

  test "somebody else is turned away with nothing shown" do
    shown!
    sign_in_as(Account.find_or_create_by!(user_id: "UMSGOTHER"))

    answering(->(*) { flunk "slack was asked for a post that is not theirs" }) do
      get @path
    end

    assert_redirected_to root_path
    assert_match(/not yours/, flash[:alert])
  end

  test "a manager is turned away too, it is the author's alone" do
    shown!
    sign_in_as(hold_role!("UMSGBOSS", "community_manager"))

    answering(->(*) { flunk "slack was asked" }) do
      get @path
    end

    assert_redirected_to root_path
  end

  test "a channel that does not show how posts did says so, even to the author" do
    sign_in_as(@author)

    answering(->(*) { flunk "slack was asked about a channel that is not shown" }) do
      get @path
    end

    assert_response :success
    assert_includes response.body, "Activity is not shown for this channel"
    refute_includes response.body, "Reach over time"
  end

  test "a post the warehouse has not landed says so without asking slack" do
    shown!
    sign_in_as(@author)

    answering(->(*) { flunk "slack was asked" }) do
      get message_activity_path(@post.channel_id, "1.000001")
    end

    assert_response :success
    assert_includes response.body, "Post not in the warehouse yet"
  end

  test "when slack will not answer the page still stands" do
    shown!
    sign_in_as(@author)

    answering(->(*) { raise Slack::ProxyClient::Error, "down" }) do
      get @path
    end

    assert_response :success
    assert_includes response.body, "No activity returned"
  end

  test "a stranger is sent to the door" do
    get @path

    assert_response :redirect
  end
end
