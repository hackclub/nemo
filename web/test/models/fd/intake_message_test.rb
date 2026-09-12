require "test_helper"

class Fd::IntakeMessageTest < ActiveSupport::TestCase
  def conversation
    kase = make_case
    report = Fd::CaseReport.create!(case_id: kase.id, reporter_user_id: "UREP1",
      is_anonymous: false, source_app: "shroud", received_at: 3.days.ago)
    Fd::IntakeConversation.create!(report_id: report.id, channel_id: "D0REP",
      thread_ts: "1.0", opened_at: 3.days.ago)
  end

  def message(conversation_id, at:)
    Fd::IntakeMessage.create!(conversation_id: conversation_id, channel_id: "D0REP",
      ts: "#{at.to_i}.0001", direction: "inbound", author_user_id: "UREP1",
      body: "hi", posted_at: at)
  end

  test "earlier_than counts what the tail leaves out" do
    convo = conversation
    5.times { |i| message(convo.id, at: (5 - i).days.ago) }

    assert_equal 2, Fd::IntakeMessage.earlier_than([convo.id], 3)
    assert_equal 0, Fd::IntakeMessage.earlier_than([convo.id], 5)
    assert_equal 0, Fd::IntakeMessage.earlier_than([convo.id], 50)
  end

  test "earlier_than is zero with no conversation to search" do
    assert_equal 0, Fd::IntakeMessage.earlier_than([], 0)
    assert_equal 0, Fd::IntakeMessage.earlier_than(nil, 0)
  end

  test "tail with a wider limit reveals what a narrower one left out" do
    convo = conversation
    6.times { |i| message(convo.id, at: (6 - i).days.ago) }

    narrow = Fd::IntakeMessage.tail([convo.id], limit: 3)
    wide = Fd::IntakeMessage.tail([convo.id], limit: 10)

    assert_equal 3, narrow.size
    assert_equal 6, wide.size
    assert_equal wide.last(3).map(&:id), narrow.map(&:id)
    assert_equal wide.map(&:posted_at), wide.map(&:posted_at).sort,
      "both the wide and narrow tail must read oldest first"
  end
end
