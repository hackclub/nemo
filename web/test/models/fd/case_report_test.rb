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
    refute report.told_of_outcome?, "closing the case only means telling them was requested"
  end

  test "closing the case without a reachable conversation cannot claim delivery" do
    report = file(closed_at: Time.current, closed_by: "UFF1")

    assert_equal :unreachable, report.outcome_state
    refute report.told_of_outcome?
  end

  test "an outcome message only counts once it is actually sent" do
    report = file(closed_at: Time.current, closed_by: "UFF1")
    conversation = Fd::IntakeConversation.create!(report_id: report.id, channel_id: "D0REP",
      thread_ts: "1.0", opened_at: 6.days.ago)
    outbox = Fd::IntakeOutbox.create!(conversation_id: conversation.id, kind: "outcome",
      body: "here's what happened", mode: "signed", requested_by: "UFF1")

    assert_equal :queued, report.outcome_state
    refute report.told_of_outcome?

    outbox.update!(failed_at: Time.current, error: "channel_not_found")
    assert_equal :failed, report.outcome_state
    refute report.told_of_outcome?

    outbox.update!(failed_at: nil, error: nil, sent_at: Time.current)
    assert_equal :sent, report.outcome_state
    assert report.told_of_outcome?
    assert_match(/told the outcome/, report.closed_line({ "UFF1" => "Robin" }))
  end
end
