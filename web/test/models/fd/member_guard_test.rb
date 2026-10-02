require "test_helper"

class Fd::MemberGuardTest < ActiveSupport::TestCase
  def open!(**over)
    Fd::MemberGuard.open!(
      **{ kind: "shush", subject_id: "USUB", by: "UMOD", reason: "being awful",
          expires_at: 7.days.from_now }.merge(over)
    )
  end

  test "a second live guard comes back nil without poisoning the transaction" do
    Fd::MemberGuard.transaction do
      assert open!
      assert_nil open!
      assert_equal 1, Fd::MemberGuard.count
      assert Fd::MemberGuard.create!(kind: "channel_ban", subject_id: "USUB",
        channel_id: "C1", opened_by: "UMOD", reason: "still writable")
    end
  end

  test "attaching only wins while it is still on no case" do
    first = make_case
    second = make_case
    guard = open!
    assert guard.attach_to!(first.id)
    assert_equal first.id, guard.case_id
    assert_nil guard.attach_to!(second.id)
    assert_equal first.id, guard.reload.case_id
  end

  test "lifting only wins once" do
    guard = open!
    assert guard.lift!(by: "UMOD", reason: "enough")
    assert_nil guard.lift!(by: "USOMEBODY")
    assert_equal "UMOD", guard.reload.lifted_by
  end

  test "a lifted guard can neither be re-dated nor attached" do
    guard = open!
    guard.lift!(by: "UMOD")
    assert_nil guard.run_until!(30.days.from_now)
    assert_nil guard.attach_to!(make_case.id)
  end

  test "one still being lifted is still standing" do
    guard = open!
    guard.update!(state: "lifting", lifted_by: "UMOD")
    assert_includes Fd::MemberGuard.still_on, guard
    assert_nil open!
  end

  test "settle reads a guard against the case in hand" do
    mine = make_case
    other = make_case
    guard = open!
    assert_equal Fd::MemberGuard::ORPHANED,
      Fd::MemberGuard.settle("shush", "USUB", case_id: mine.id).reads

    guard.attach_to!(mine.id)
    assert_equal Fd::MemberGuard::HERE,
      Fd::MemberGuard.settle("shush", "USUB", case_id: mine.id).reads
    assert_equal Fd::MemberGuard::ELSEWHERE,
      Fd::MemberGuard.settle("shush", "USUB", case_id: other.id).reads
  end

  test "settle leaves a record only kind alone and waits for a subject" do
    open!
    held = Fd::MemberGuard.settle("warning", "USUB", case_id: make_case.id)
    assert_not held.enforceable?
    assert_nil held.guard

    waiting = Fd::MemberGuard.settle("shush", nil, case_id: make_case.id)
    assert waiting.enforceable?
    assert_nil waiting.guard
  end
end
