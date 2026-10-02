require "test_helper"

class Channels::WelcomeTest < ActiveSupport::TestCase
  def build(**rest)
    row = Analytics::MartChannelNewcomers.new({
      channel_id: "C1", newcomers: 100, answered_by_member: 80, answered_fast: 60,
      answered_by_bot: 5, unanswered: 15, measured_day_30: 90, returned_day_30: 45,
      answered_share: 0.8, fast_share: 0.6, returned_share: 0.5,
      median_latency_seconds: 372, fast_reply_seconds: 3600
    }.merge(rest))
    Channels::Welcome.new(row, "C1")
  end

  test "a channel nobody landed in has nothing to show" do
    welcome = Channels::Welcome.new(nil, "C1")

    assert_not welcome.any?
    assert_empty welcome.funnel
    assert_nil welcome.returned
  end

  test "a channel with no first post has no funnel" do
    welcome = build(newcomers: 0)

    assert_not welcome.any?
    assert_empty welcome.funnel
  end

  test "every step counts against the same base, the first posts that landed" do
    steps = build.funnel

    assert_equal %w[landed answered fast], steps.map(&:key)
    assert_equal [100, 80, 60], steps.map(&:count)
    assert_equal [100.0, 80.0, 60.0], steps.map(&:share)
  end

  test "the funnel only ever narrows" do
    shares = build.funnel.map(&:share)

    assert_equal shares.sort.reverse, shares
  end

  test "coming back is measured against the newcomers old enough to judge" do
    back = build(measured_day_30: 90, returned_day_30: 45).returned

    assert_equal 45, back.count
    assert_equal 50.0, back.share
  end

  test "coming back says nothing until somebody is old enough to judge" do
    assert_nil build(measured_day_30: 0).returned
  end

  test "each step records who it lost" do
    steps = build.funnel

    assert_nil steps[0].lost
    assert_equal 20, steps[1].lost
    assert_equal 20, steps[2].lost
  end

  test "the fast threshold is read from the warehouse, not hardcoded" do
    assert_equal "an hour", build.fast_label
    assert_equal "15 min", build(fast_reply_seconds: 900).fast_label
    assert_equal "6h", build(fast_reply_seconds: 21_600).fast_label
  end
end
