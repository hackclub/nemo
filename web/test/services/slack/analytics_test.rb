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
end
