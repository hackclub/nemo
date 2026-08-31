require "test_helper"

class ChannelManagersTest < ActiveSupport::TestCase
  CHANNEL = "C0BGRUMA85D".freeze

  setup do
    @asked = []
    @was_role = ENV["SLACK_CHANNEL_MANAGER_ROLE_ID"]
    ENV["SLACK_CHANNEL_MANAGER_ROLE_ID"] = "Rl0A"
    Api::ChannelManager.delete_all
    Api::ChannelSweep.delete_all
    Rails.cache.clear
  end

  teardown do
    ENV["SLACK_CHANNEL_MANAGER_ROLE_ID"] = @was_role
  end

  def swapping(replier)
    was = Slack::ProxyClient.method(:call)
    Slack::ProxyClient.define_singleton_method(:call, &replier)
    yield
  ensure
    Slack::ProxyClient.define_singleton_method(:call, was)
  end

  def page(*user_ids, on: CHANNEL, cursor: nil)
    {
      "ok" => true,
      "role_assignments" => user_ids.map do |user_id|
        { "role_id" => "Rl0A", "entity_id" => on, "user_id" => user_id,
          "date_create" => 1_700_000_000 }
      end,
      "response_metadata" => { "next_cursor" => cursor.to_s }
    }
  end

  def answering(*pages, &block)
    replies = pages.dup
    asked = @asked
    fallback = page
    swapping(lambda { |method, params, **options|
      asked << [method, params, options]
      replies.shift || fallback
    }, &block)
  end

  def raising(error, &block)
    asked = @asked
    swapping(lambda { |*_args, **_options|
      asked << :tried
      raise error
    }, &block)
  end

  test "a channel nobody has asked about is fetched once and remembered" do
    found = answering(page("U1", "U2")) { ChannelManagers.for(CHANNEL) }

    assert_equal %w[U1 U2], found
    assert_equal 1, @asked.size
    assert_equal %w[U1 U2], Api::ChannelManager.user_ids_in(CHANNEL)
    assert_equal 2, Api::ChannelSweep.find(CHANNEL).managers
  end

  test "it asks slack for one channel and one role, never the whole workspace" do
    answering(page("U1")) { ChannelManagers.for(CHANNEL) }

    method, params, options = @asked.sole
    assert_equal "admin.roles.listAssignments", method
    assert_equal "Rl0A", params[:role_ids]
    assert_equal CHANNEL, params[:entity_ids]
    assert_equal "admin", options[:credential]
  end

  test "a fresh channel is answered without troubling slack at all" do
    answering(page("U1")) { ChannelManagers.for(CHANNEL) }
    @asked.clear

    found = answering { ChannelManagers.for(CHANNEL) }

    assert_equal %w[U1], found
    assert_empty @asked, "a warm channel must cost nothing"
  end

  test "a channel nobody manages is remembered as empty, not refetched forever" do
    answering(page) { ChannelManagers.for(CHANNEL) }
    @asked.clear

    assert_empty answering { ChannelManagers.for(CHANNEL) }
    assert_empty @asked, "no rows is an answer, not a cold cache"
    assert_equal 0, Api::ChannelSweep.find(CHANNEL).managers
  end

  test "once the stamp goes stale it is fetched again" do
    answering(page("U1")) { ChannelManagers.for(CHANNEL) }
    Api::ChannelSweep.find(CHANNEL).update!(synced_at: 2.hours.ago)
    @asked.clear

    found = answering(page("U2")) { ChannelManagers.for(CHANNEL) }

    assert_equal %w[U2], found
    assert_equal 1, @asked.size
  end

  test "a refresh replaces the channel, so somebody who stepped down stops managing it" do
    answering(page("U1", "U2")) { ChannelManagers.for(CHANNEL) }
    Api::ChannelSweep.find(CHANNEL).update!(synced_at: 2.hours.ago)

    answering(page("U2")) { ChannelManagers.for(CHANNEL) }

    assert_equal %w[U2], Api::ChannelManager.user_ids_in(CHANNEL)
    assert_not ChannelManagers.manages?(CHANNEL, "U1")
  end

  test "a stale channel already being refreshed is not fetched a second time" do
    with_a_real_cache do
      answering(page("U1")) { ChannelManagers.for(CHANNEL) }
      Api::ChannelSweep.find(CHANNEL).update!(synced_at: 2.hours.ago)
      @asked.clear
      ChannelManagers.claim(CHANNEL)

      found = answering(page("U2")) { ChannelManagers.for(CHANNEL) }

      assert_empty @asked, "somebody else holds the lock, so this caller serves what we have"
      assert_equal %w[U1], found
    end
  end

  test "a cold channel is always fetched, lock or no lock" do
    with_a_real_cache do
      ChannelManagers.claim(CHANNEL)

      found = answering(page("U1")) { ChannelManagers.for(CHANNEL) }

      assert_equal %w[U1], found,
        "answering false about a channel we never read is worse than waiting"
    end
  end

  test "a refreshed channel is fresh again, so the next caller asks nothing" do
    answering(page("U1")) { ChannelManagers.for(CHANNEL) }
    Api::ChannelSweep.find(CHANNEL).update!(synced_at: 2.hours.ago)
    @asked.clear

    answering(page("U2")) { ChannelManagers.for(CHANNEL) }
    answering(page("U3")) { ChannelManagers.for(CHANNEL) }

    assert_equal 1, @asked.size
    assert_equal %w[U2], Api::ChannelManager.user_ids_in(CHANNEL)
  end

  test "slack falling over serves what we already hold and leaves the stamp alone" do
    answering(page("U1")) { ChannelManagers.for(CHANNEL) }
    stamped = Api::ChannelSweep.find(CHANNEL).synced_at
    Api::ChannelSweep.find(CHANNEL).update!(synced_at: 2.hours.ago)

    found = raising(Slack::ProxyClient::Unavailable) { ChannelManagers.for(CHANNEL) }

    assert_equal %w[U1], found
    assert_not_equal stamped, Api::ChannelSweep.find(CHANNEL).synced_at
    assert_equal %w[U1], Api::ChannelManager.user_ids_in(CHANNEL)
  end

  test "a refusal from slack does not wipe the channel" do
    answering(page("U1")) { ChannelManagers.for(CHANNEL) }
    Api::ChannelSweep.find(CHANNEL).update!(synced_at: 2.hours.ago)

    answering({ "ok" => false, "error" => "missing_scope" }) { ChannelManagers.for(CHANNEL) }

    assert_equal %w[U1], Api::ChannelManager.user_ids_in(CHANNEL)
  end

  test "an assignment on some other channel is dropped, whatever slack sends" do
    answering(page("U1", on: "COTHER")) { ChannelManagers.for(CHANNEL) }

    assert_empty Api::ChannelManager.user_ids_in(CHANNEL)
    assert_equal 0, Api::ChannelSweep.find(CHANNEL).managers
  end

  test "it follows the cursor to the end" do
    found = answering(page("U1", cursor: "more"), page("U2")) { ChannelManagers.for(CHANNEL) }

    assert_equal %w[U1 U2], found
    assert_equal 2, @asked.size
    assert_nil @asked.first[1][:cursor], "the first call sends no cursor at all"
    assert_equal "more", @asked.last[1][:cursor]
  end

  test "with no role id pinned it asks nothing and claims nothing" do
    ENV["SLACK_CHANNEL_MANAGER_ROLE_ID"] = nil
    found = answering(page("U1")) { ChannelManagers.for(CHANNEL) }

    assert_empty found
    assert_empty @asked
    assert_nil Api::ChannelSweep.find_by(channel_id: CHANNEL)
  end

  test "a blank channel id is answered without a query" do
    assert_empty answering { ChannelManagers.for("") }
    assert_empty @asked
  end
end
