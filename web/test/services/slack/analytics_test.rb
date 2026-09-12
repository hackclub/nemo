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

  def windows(**over)
    Slack::Analytics.channel_windows(
      **{ channel_id: "C1", name: "general", privacy: "public",
          windows: [["2026-08-01", "2026-08-07"], ["2026-01-01", "2026-08-07"]] }.merge(over)
    )
  end

  test "both windows answer, in the order they were asked for" do
    caching do
      answering(one_channel) do |calls|
        first, second = windows

        assert_equal 2, calls.call
        assert_equal 12, first.stats["messages_count"]
        assert_equal 12, second.stats["messages_count"]
      end
    end
  end

  test "the cache is touched only on the calling thread, never on a fetch thread" do
    caching do
      answering(one_channel) do |_calls|
        mine = Thread.current
        touched = Queue.new
        store = Rails.cache
        recorder = Class.new(SimpleDelegator) do
          define_method(:read) { |*a, **k| touched << Thread.current; __getobj__.read(*a, **k) }
          define_method(:write) { |*a, **k| touched << Thread.current; __getobj__.write(*a, **k) }
        end.new(store)

        Rails.cache = recorder
        windows
        Rails.cache = store

        seen = []
        seen << touched.pop until touched.empty?

        refute_empty seen, "the cache was never touched, so this proves nothing"
        assert_equal [mine], seen.uniq,
          "a fetch thread reached the cache, which is a table in the request's own pool"
      end
    end
  end

  test "a window already cached is not asked for again" do
    caching do
      answering(one_channel) do |calls|
        windows
        windows

        assert_equal 2, calls.call, "the second pair of windows must come from the cache"
      end
    end
  end
end
