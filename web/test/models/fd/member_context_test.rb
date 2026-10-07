require "test_helper"

class Fd::MemberContextTest < ActiveSupport::TestCase
  MINE = "USUB".freeze

  def context_for(user_id = MINE)
    Fd::MemberContext.for([user_id]).fetch(user_id)
  end

  def window_label(at)
    Analytics::MemberWindow.new(user_id: MINE, last_active_at: at,
      source: Analytics::MemberWindow::LIFETIME_SOURCE)
  end

  def archive_said(at)
    Analytics::MemberLifetimeMessages.new(user_id: MINE, last_at: at)
  end

  def built(window:, archive:)
    Fd::MemberContext.new(MINE, nil, window, archive)
  end

  test "the newest message wins when the analytics window is behind it" do
    behind = 3.days.ago.change(usec: 0)
    fresh = 1.hour.ago.change(usec: 0)

    person = built(window: window_label(behind), archive: archive_said(fresh))

    assert_equal fresh, person.last_active_at
  end

  test "the analytics window wins when somebody was about without posting" do
    read = 1.hour.ago.change(usec: 0)
    posted = 9.days.ago.change(usec: 0)

    person = built(window: window_label(read), archive: archive_said(posted))

    assert_equal read, person.last_active_at
  end

  test "either source alone is enough" do
    at = 2.hours.ago.change(usec: 0)

    assert_equal at, built(window: window_label(at), archive: nil).last_active_at
    assert_equal at, built(window: nil, archive: archive_said(at)).last_active_at
    assert_nil built(window: nil, archive: nil).last_active_at
  end

  test "a window that knows nothing does not hide a message we hold" do
    at = 5.minutes.ago.change(usec: 0)

    person = built(window: window_label(nil), archive: archive_said(at))

    assert_equal at, person.last_active_at
    assert_equal at, person.last_posted_at
  end

  test "looking somebody up reads both sources" do
    assert_nothing_raised { context_for }
  end

  test "a member the warehouse has not met yet takes their tenure from the day they joined" do
    joined = 2.days.ago.change(usec: 0)

    person = Fd::MemberContext.new(MINE, nil, nil, nil, joined)

    assert_equal joined, person.cohort_at
    assert_equal 2, person.tenure_days
  end

  test "the warehouse cohort wins over the join day when both are known" do
    cohort = 400.days.ago.change(usec: 0)
    member = Analytics::DimMember.new(user_id: MINE, cohort_at: cohort)

    person = Fd::MemberContext.new(MINE, member, nil, nil, 1.day.ago)

    assert_equal cohort, person.cohort_at
  end
end
