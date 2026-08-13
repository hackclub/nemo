require "test_helper"

class Fd::CaseReportTest < ActiveSupport::TestCase
  setup do
    @case = make_case
  end

  def file(**attrs)
    Fd::CaseReport.create!({
      case_id: @case.id, received_at: 5.days.ago, source_app: "shroud",
      is_anonymous: false, reporter_user_id: "UREP1"
    }.merge(attrs))
  end

  test "a report with no first reply is unanswered" do
    assert file.unanswered?
  end

  test "a report that has been replied to is answered" do
    refute file(first_replied_at: 4.days.ago).unanswered?
  end

  test "waiting_for counts from when it arrived until now" do
    now = Time.current
    report = file(received_at: now - 5.days)

    assert_in_delta 5.days, report.waiting_for(now), 1
  end

  test "waiting_for is nil once somebody has replied" do
    assert_nil file(first_replied_at: 1.day.ago).waiting_for
  end

  test "being told the outcome is separate from being replied to" do
    report = file(first_replied_at: 4.days.ago)

    refute report.told_of_outcome?, "a reply is not the outcome"
    report.update!(closed_at: Time.current, closed_by: "UFF1")
    assert report.told_of_outcome?
  end
end
