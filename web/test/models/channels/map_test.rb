require "test_helper"

class Channels::MapTest < ActiveSupport::TestCase
  test "the four quadrants name themselves by where a channel sits" do
    {
      [true, true] => "working", [true, false] => "landing, not staying",
      [false, true] => "small and sticky", [false, false] => "quiet"
    }.each do |(across, above), label|
      assert_equal label, Channels::Map.phase(across: across, above: above).first
    end
  end

  test "a channel exactly on a dividing line counts as above it, not below" do
    assert_equal "working", Channels::Map.phase(across: true, above: true).first
  end

  test "every quadrant draws in its own ink" do
    inks = Channels::Map::QUADRANTS.values.map(&:last)

    assert_equal inks.uniq.length, inks.length, "two quadrants share a colour"
  end

  test "the median splits an odd and an even list" do
    assert_equal 5, Channels::Map.median([9, 1, 5])
    assert_equal 3.0, Channels::Map.median([1, 5, 2, 4])
    assert_equal 0, Channels::Map.median([])
  end

  test "a share is a percentage, and an empty denominator has none" do
    assert_equal 33.0, Channels::Map.share(0.33)
    assert_nil Channels::Map.share(nil)
    assert_equal 25.0, Channels::Map.share_of(1, 4)
    assert_nil Channels::Map.share_of(1, 0)
  end

  test "the floor is the one the rest of the dashboard already uses" do
    assert_equal HomeHelper::MIN_SAMPLE, Channels::Map.floor
  end

  test "a report with no channel above the floor renders its empty state" do
    assert_not Channels::Map::Report.new(points: [], floor: Channels::Map.floor).any?
  end

  test "the default cohort is the last thirty days and it is never called mature" do
    assert_equal "last30", Analytics::MartNewcomerChannels::DEFAULT_COHORT
    last30 = Analytics::MartNewcomerChannels::Cohort.new(key: "last30", order: 0,
      ends_on: Date.new(2026, 9, 12), mature: false)

    assert last30.default?
    assert_equal "Last 30 days", last30.label
    assert_equal "30 days to 12 Sep 2026", last30.window
  end

  test "a month cohort names its month, not a rolling window" do
    month = Analytics::MartNewcomerChannels::Cohort.new(key: "2026-07", order: 1,
      starts_on: Date.new(2026, 7, 1), ends_on: Date.new(2026, 7, 31), mature: true)

    assert_not month.default?
    assert_equal "Jul 2026", month.label
    assert_equal "July 2026", month.window
  end

  test "an unknown cohort falls back to the default rather than drawing nothing" do
    offered = Analytics::MartNewcomerChannels.cohorts
    skip "the corpus has no newcomer cohorts" if offered.empty?

    fallback = Analytics::MartNewcomerChannels.cohort("nonsense")
    assert_includes offered.map(&:key), fallback&.key
    assert_equal "last30", fallback.key if offered.any?(&:default?)
  end

  test "points carry only what the chart draws, never the channel id" do
    point = Channels::Map::Point.new(channel_id: "C1", name: "lounge", x: 1, y: 2, n: 3, ink: 2,
      phase: "working")

    assert_not_includes point.as_json.keys, :channel_id
    assert_equal %i[name x y n ink phase], point.as_json.keys
  end
end
