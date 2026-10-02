require "test_helper"

class Analytics::MartCohortSurvivalTest < ActiveSupport::TestCase
  def curve(shares)
    Analytics::MartCohortSurvival::Curve.new(cohort_month: Date.new(2026, 4, 1), members: 100,
      shares: shares)
  end

  test "a curve is drawn as far as its last observed day, not to the horizon" do
    assert_equal 2, curve([100.0, 80.0, 60.0, nil, nil]).drawn_to
  end

  test "a cohort that has aged through the whole horizon is not partial" do
    ladder = (0..3).to_a

    assert_not curve([100.0, 80.0, 60.0, 40.0]).partial?(ladder)
    assert curve([100.0, 80.0, nil, nil]).partial?(ladder)
  end

  test "an unobserved day reads as nothing, never as zero" do
    assert_nil curve([100.0, nil]).at(1)
  end

  test "survival never rises as the days pass" do
    shares = [100.0, 74.0, 52.0, 28.0]

    assert_equal shares, shares.sort.reverse, "a member who stopped cannot come back to the curve"
  end
end
