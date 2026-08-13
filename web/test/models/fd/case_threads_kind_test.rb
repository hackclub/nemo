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

  test "a thread is evidence unless it says otherwise" do
    assert attach(@one, "C1", "1.1").evidence?
  end

  test "two cases citing the same evidence thread are siblings" do
    attach(@one, "C1", "1.1", is_primary: true)
    attach(@two, "C1", "1.1", is_primary: true)

    assert_equal [@two.id], @one.sibling_cases.pluck(:id)
    assert_equal [@one.id], @two.sibling_cases.pluck(:id)
  end

  test "two cases discussed in one FD thread are not siblings" do
    attach(@one, "C-HQ", "9.9", kind: "internal")
    attach(@two, "C-HQ", "9.9", kind: "internal")

    assert_empty @one.sibling_cases,
      "an internal FD discussion must not make unrelated cases look like duplicates"
    assert_empty @two.sibling_cases
  end

  test "an internal thread on one side does not match evidence on the other" do
    attach(@one, "C1", "1.1", is_primary: true)
    attach(@two, "C1", "1.1", kind: "internal")

    assert_empty @one.sibling_cases
    assert_empty @two.sibling_cases
  end

  test "a case with only internal threads has no siblings to look for" do
    attach(@one, "C-HQ", "9.9", kind: "internal")
    attach(@two, "C1", "1.1", is_primary: true)

    assert_empty @one.sibling_cases
  end

  test "siblings still work when a case carries both kinds" do
    attach(@one, "C1", "1.1", is_primary: true)
    attach(@one, "C-HQ", "9.9", kind: "internal")
    attach(@two, "C1", "1.1", is_primary: true)
    attach(@two, "C-HQ", "9.9", kind: "internal")

    assert_equal [@two.id], @one.sibling_cases.pluck(:id)
  end

  test "the primary thread cannot be an internal one" do
    assert_raises(ActiveRecord::StatementInvalid) do
      attach(@one, "C-HQ", "9.9", kind: "internal", is_primary: true)
    end
  end

  test "a kind outside the two is refused by the database" do
    assert_raises(ActiveRecord::StatementInvalid) do
      attach(@one, "C1", "1.1", kind: "deliberation")
    end
  end

  test "the scopes split the two kinds" do
    attach(@one, "C1", "1.1", is_primary: true)
    attach(@one, "C-HQ", "9.9", kind: "internal")

    assert_equal ["C1"], @one.threads.evidence.pluck(:channel_id)
    assert_equal ["C-HQ"], @one.threads.internal.pluck(:channel_id)
  end
end
