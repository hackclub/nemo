require "test_helper"

class Fd::CaseReportTest < ActiveSupport::TestCase
  setup do
    @case = make_case
  end

  def create_report(**attrs)
    Fd::CaseReport.create!({
      case_id: @case.id, received_at: 5.days.ago, source_app: "relay",
      is_anonymous: false, reporter_user_id: "UREP1"
    }.merge(attrs))
  end

  test "unanswered? is true without first_replied_at" do
    assert create_report.unanswered?
  end

  test "unanswered? is false with first_replied_at" do
    refute create_report(first_replied_at: 4.days.ago).unanswered?
  end

  test "waiting_for returns the elapsed time from received_at" do
    now = Time.current
    report = create_report(received_at: now - 5.days)

    assert_in_delta 5.days, report.waiting_for(now), 1
  end

  test "waiting_for is nil with first_replied_at" do
    assert_nil create_report(first_replied_at: 1.day.ago).waiting_for
  end

  test "outcome_notified? is false with only a reply and true after closing" do
    report = create_report(first_replied_at: 4.days.ago)

    refute report.outcome_notified?, "a reply is not the outcome"
    report.update!(closed_at: Time.current, closed_by: "UFF1")
    assert report.outcome_notified?
  end

  test "threads_besides lists the threads of the other reports" do
    first = create_report(forwarded_ts: "100.1")
    second = create_report(forwarded_ts: "200.1")
    unposted = create_report(forwarded_ts: nil)
    reports = [first, second, unposted]

    assert_equal ["200.1"], Fd::CaseReport.threads_besides(reports, first)
    assert_equal ["100.1", "200.1"], Fd::CaseReport.threads_besides(reports, unposted)
    assert_equal [], Fd::CaseReport.threads_besides(reports, nil)
  end
end
