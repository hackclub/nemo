require "test_helper"

class Slack::AnalyticsTest < ActiveSupport::TestCase
  test "parallel keeps results in the order the tasks were given" do
    assert_equal [:a, :b, :c], Slack::Analytics.parallel(
      -> { sleep 0.05; :a },
      -> { :b },
      -> { sleep 0.02; :c }
    )
  end

  test "parallel raises what a task raised" do
    was = Thread.report_on_exception
    Thread.report_on_exception = false
    err = assert_raises(RuntimeError) do
      Slack::Analytics.parallel(-> { :ok }, -> { raise "boom" })
    end
    assert_equal "boom", err.message
  ensure
    Thread.report_on_exception = was
  end

  test "parallel overlaps its tasks" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Slack::Analytics.parallel(-> { sleep 0.5 }, -> { sleep 0.5 })
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.9, "tasks ran one after the other, taking #{elapsed.round(2)}s"
  end

  ONE = { "channel_id" => "C1", "name" => "general", "messages_count" => 12 }.freeze

  def caching
    was = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = was
  end

  def ask(**over)
    Slack::Analytics.channel_activity(
      **{ channel_id: "C1", name: "general", from: "2026-08-01", to: "2026-08-07" }.merge(over)
    )
  end

  RANGE = { "start_date" => "2026-01-01", "end_date" => "2026-12-31" }.freeze

  def answering(reply)
    was = Slack::ProxyClient.method(:call)
    count = 0
    Slack::ProxyClient.define_singleton_method(:call) do |method, *rest|
      next RANGE if method == "admin.analytics.getAvailableDateRange"

      count += 1
      reply.call(method, *rest)
    end
    yield -> { count }
  ensure
    Slack::ProxyClient.define_singleton_method(:call, was)
  end

  def one_channel = ->(*) { { "channel_analytics" => [ONE] } }

  test "a second look at the same window does not call slack again" do
    caching do
      answering(one_channel) do |calls|
        first = ask
        second = ask

        assert_equal 1, calls.call, "the second look must be served from the cache"
        assert_equal 12, first.stats["messages_count"]
        assert_equal first.stats, second.stats
      end
    end
  end

  test "a different window is a different question" do
    caching do
      answering(one_channel) do |calls|
        ask
        ask(to: "2026-08-08")

        assert_equal 2, calls.call, "the date range is part of what was asked"
      end
    end
  end

  test "a failure is never cached, so a blip does not stick for hours" do
    caching do
      answering(->(*) { raise Slack::ProxyClient::Error, "down" }) do |calls|
        assert_equal :unavailable, ask.error
        assert_equal :unavailable, ask.error

        assert_equal 2, calls.call,
          "a cached error would leave the page broken until it expired"
      end
    end
  end

  test "a channel that was not found is asked about again next time" do
    caching do
      answering(->(*) { { "channel_analytics" => [], "num_found" => 0 } }) do |calls|
        assert_equal :not_found, ask.error
        ask

        assert_equal 2, calls.call
      end
    end
  end
end
