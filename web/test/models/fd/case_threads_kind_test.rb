require "test_helper"

class Fd::CaseThreadsKindTest < ActiveSupport::TestCase
  setup do
    @one = make_case
    @two = make_case
  end

  def attach(kase, channel, ts, **attrs)
    Fd::CaseThread.create!({
      case_id: kase.id, channel_id: channel, thread_ts: ts, added_by: "UFF1"
    }.merge(attrs))
  end

  test "CaseThread kind defaults to evidence" do
    assert attach(@one, "C1", "1.1").evidence?
  end

  test "kind_for is internal in an FD channel and evidence anywhere else" do
    Fd::AppSetting.set_firehouse_channel("GTESTFIRE", by: "UFF1")

    assert_equal "internal", Fd::CaseThread.kind_for("GTESTFIRE")
    assert_equal "evidence", Fd::CaseThread.kind_for("C0LOUNGE")
  end

  test "sibling_cases skips a thread removed from the other case" do
    attach(@one, "C1", "1.1", is_primary: true)
    attach(@two, "C1", "1.1", removed_at: Time.current, removed_by: "UFF1")

    assert_empty @one.sibling_cases
  end

  test "sibling_cases includes cases sharing an evidence thread" do
    attach(@one, "C1", "1.1", is_primary: true)
    attach(@two, "C1", "1.1", is_primary: true)

    assert_equal [@two.id], @one.sibling_cases.pluck(:id)
    assert_equal [@one.id], @two.sibling_cases.pluck(:id)
  end

  test "sibling_cases excludes cases sharing an internal thread" do
    attach(@one, "C-HQ", "9.9", kind: "internal")
    attach(@two, "C-HQ", "9.9", kind: "internal")

    assert_empty @one.sibling_cases,
      "internal thread does not create siblings"
    assert_empty @two.sibling_cases
  end

  test "sibling_cases excludes an internal thread matching an evidence thread" do
    attach(@one, "C1", "1.1", is_primary: true)
    attach(@two, "C1", "1.1", kind: "internal")

    assert_empty @one.sibling_cases
    assert_empty @two.sibling_cases
  end

  test "sibling_cases is empty for a case with only internal threads" do
    attach(@one, "C-HQ", "9.9", kind: "internal")
    attach(@two, "C1", "1.1", is_primary: true)

    assert_empty @one.sibling_cases
  end

  test "sibling_cases matches on evidence thread when a case has both kinds" do
    attach(@one, "C1", "1.1", is_primary: true)
    attach(@one, "C-HQ", "9.9", kind: "internal")
    attach(@two, "C1", "1.1", is_primary: true)
    attach(@two, "C-HQ", "9.9", kind: "internal")

    assert_equal [@two.id], @one.sibling_cases.pluck(:id)
  end

  test "CaseThread create with kind internal and is_primary raises StatementInvalid" do
    assert_raises(ActiveRecord::StatementInvalid) do
      attach(@one, "C-HQ", "9.9", kind: "internal", is_primary: true)
    end
  end

  test "CaseThread create with unknown kind raises StatementInvalid" do
    assert_raises(ActiveRecord::StatementInvalid) do
      attach(@one, "C1", "1.1", kind: "deliberation")
    end
  end

  test "threads evidence and internal scopes filter by kind" do
    attach(@one, "C1", "1.1", is_primary: true)
    attach(@one, "C-HQ", "9.9", kind: "internal")

    assert_equal ["C1"], @one.threads.evidence.pluck(:channel_id)
    assert_equal ["C-HQ"], @one.threads.internal.pluck(:channel_id)
  end
end
