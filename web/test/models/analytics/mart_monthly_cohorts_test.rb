require "test_helper"

class Analytics::MartMonthlyCohortsTest < ActiveSupport::TestCase
  def cohort(month)
    Analytics::MartMonthlyCohorts.new(cohort_month: month)
  end

  test "the month in progress is never mature" do
    assert_not cohort(Date.current.beginning_of_month).mature?,
      "nobody who joined this month has had 30 days yet"
  end

  test "a cohort is mature once every member has had a full 30 days" do
    old = (Date.current - 120).beginning_of_month

    assert cohort(old).mature?
  end

  test "maturity turns exactly 30 days after the month ends" do
    month = (Date.current - 60).beginning_of_month
    closes = month.end_of_month

    travel_to(closes + 29) { assert_not cohort(month).mature? }
    travel_to(closes + 30) { assert cohort(month).mature? }
  end

  test "the date it matures is the one the page shows" do
    month = Date.new(2026, 8, 1)

    assert_equal Date.new(2026, 9, 30), cohort(month).matures_on
  end
end
