require "test_helper"

module Fd
  class StartTimeTest < ActiveSupport::TestCase
    NOW = Time.utc(2026, 11, 5, 9, 0)

    test "read with no date and no time has no start" do
      assert_equal [nil, nil], StartTime.read("", "", now: NOW)
    end

    test "read with a date only starts at midnight utc" do
      assert_equal [Time.utc(2026, 11, 10), nil], StartTime.read("2026-11-10", "", now: NOW)
    end

    test "read with a date and time starts at that time in utc" do
      assert_equal [Time.utc(2026, 11, 10, 14, 30), nil], StartTime.read("2026-11-10", "14:30", now: NOW)
    end

    test "read with a start that has passed returns the future error" do
      assert_equal [nil, "Start must be in the future"], StartTime.read("2026-11-05", "08:59", now: NOW)
    end

    test "read with an invalid date or time returns an error containing the input" do
      assert_equal [nil, "the ninth is not a date"], StartTime.read("the ninth", "", now: NOW)
      assert_equal [nil, "25:00 is not a time"], StartTime.read("2026-11-10", "25:00", now: NOW)
    end

    test "read with a time and no date returns the enter a date error" do
      assert_equal [nil, "Enter a date for the start time"], StartTime.read("", "14:30", now: NOW)
    end

    test "error is set only when the end is not after the start" do
      starts = Time.utc(2026, 11, 10)

      assert_nil StartTime.error(nil, starts)
      assert_nil StartTime.error(starts, nil)
      assert_nil StartTime.error(starts, starts + 1.day)
      assert_equal "End must be after the start", StartTime.error(starts, starts)
    end
  end
end
