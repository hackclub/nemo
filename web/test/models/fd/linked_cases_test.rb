require "test_helper"

class Fd::LinkedCasesTest < ActiveSupport::TestCase
  def ref(channel_id, thread_ts)
    Fd::SlackLink::Ref.new(channel_id: channel_id, thread_ts: thread_ts)
  end

  def report_in!(kase, forwarded_ts, channel_id: "C0FIRE")
    Fd::CaseReport.create!(case_id: kase.id, is_anonymous: true, body: "spam",
      received_at: 1.day.ago, source_app: "shroud", card_channel_id: channel_id, forwarded_ts: forwarded_ts)
  end

  test "for finds the case and report of a report thread" do
    kase = make_case
    report = report_in!(kase, "1788739817.138689")

    target = Fd::LinkedCases.for([ref("C0FIRE", "1788739817.138689")])[["C0FIRE", "1788739817.138689"]]

    assert_equal kase.id, target.case_id
    assert_equal report.id, target.report_id
    assert_equal kase.id, target.root_id
  end

  test "for points a merged case at the case it was merged into" do
    root = make_case
    middle = make_case(duplicate_of: root.id)
    merged = make_case(duplicate_of: middle.id)
    report_in!(merged, "1788975500.247299")

    target = Fd::LinkedCases.for([ref("C0FIRE", "1788975500.247299")])[["C0FIRE", "1788975500.247299"]]

    assert_equal merged.id, target.case_id
    assert_equal root.id, target.root_id
  end

  test "for finds a case by its card thread" do
    kase = make_case(card_channel_id: "C0FIRE", card_thread_ts: "1788884835.063919")

    target = Fd::LinkedCases.for([ref("C0FIRE", "1788884835.063919")])[["C0FIRE", "1788884835.063919"]]

    assert_equal kase.id, target.case_id
    assert_nil target.report_id
  end

  test "for leaves out threads in another channel and unknown threads" do
    report_in!(make_case, "1788739817.138689")

    assert_empty Fd::LinkedCases.for([ref("C0OTHER0", "1788739817.138689"), ref("C0FIRE", "1.1")])
  end
end
