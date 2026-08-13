require "test_helper"

class Fd::QueueStatsTest < ActiveSupport::TestCase
  def stats = Fd::QueueStats.load

  test "opening a case moves open, unassigned and the total together" do
    before = stats
    make_case(opened_at: 1.hour.ago)
    after = stats

    assert_equal before.total + 1, after.total
    assert_equal before.open_count + 1, after.open_count
    assert_equal before.unassigned + 1, after.unassigned
  end

  test "assigning a case takes it out of unassigned but leaves it open" do
    kase = make_case(opened_at: 1.hour.ago)
    before = stats
    kase.assign!("UME")
    after = stats

    assert_equal before.unassigned - 1, after.unassigned
    assert_equal before.open_count, after.open_count
  end

  test "logging an action takes a case out of the no-action count" do
    kase = make_case(opened_at: 1.hour.ago)
    before = stats
    Fd::Action.create!(case_id: kase.id, type_key: "warning", target_user_id: "USUB",
      decided_by: "UFF1", performed_by: "UFF1")

    assert_equal before.open_no_action - 1, stats.open_no_action
  end

  test "the oldest unassigned case is the one the chip is about" do
    make_case(opened_at: 40.days.ago)
    assert_operator stats.oldest_unassigned, :<=, 40.days.ago + 1.minute
  end

  test "a case with somebody on it never counts as the oldest unassigned" do
    lonely = make_case(opened_at: 90.days.ago)
    assert_equal lonely.opened_at.to_i, stats.oldest_unassigned.to_i

    lonely.assign!("UME")
    assert_not_equal lonely.opened_at.to_i, stats.oldest_unassigned&.to_i
  end

  test "opened this month counts how many of those are already closed" do
    before = stats
    make_case(opened_at: 2.hours.ago, resolved_at: 1.hour.ago, resolution: "no_action")
    after = stats

    assert_equal before.opened_month + 1, after.opened_month
    assert_equal before.opened_month_resolved + 1, after.opened_month_resolved
  end

  test "a case opened last month is not counted as opened this month" do
    before = stats
    make_case(opened_at: 1.month.ago.beginning_of_month + 1.day)

    assert_equal before.opened_month, stats.opened_month
    assert_equal before.total + 1, stats.total
  end

  test "the median matches the middle of what was resolved this quarter" do
    make_case(opened_at: 10.days.ago, resolved_at: 8.days.ago, resolution: "no_action")
    make_case(opened_at: 10.days.ago, resolved_at: 4.days.ago, resolution: "no_action")

    spans = Fd::Case.where(resolved_at: Time.current.beginning_of_quarter..)
      .pluck(:opened_at, :resolved_at)
      .map { |opened, resolved| resolved - opened }
      .sort

    assert_in_delta interpolate(spans), stats.median_now, 1.0
  end

  test "an empty quarter reports no median rather than zero" do
    row = Fd::QueueStats.new({})
    assert_nil row.median_now
    assert_nil row.median_before
    assert_equal 0, row.total
  end

  def interpolate(sorted)
    return nil if sorted.empty?

    spot = 0.5 * (sorted.size - 1)
    low = sorted[spot.floor]
    high = sorted[spot.ceil]
    low + ((high - low) * (spot - spot.floor))
  end
end
