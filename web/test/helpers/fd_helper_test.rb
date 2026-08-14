require "test_helper"

class FdHelperTest < ActionView::TestCase
  include FdHelper

  def kase(**attrs)
    make_case(opened_at: 5.days.ago, **attrs)
  end

  def entries(count)
    Array.new(count) { Fd::CaseTimeline::Entry.new(at: Time.current, title: "x") }
  end

  test "an open case says how old it is and who has it" do
    line = timeline_standing(make_case(opened_at: 5.days.ago, assign: "UFF2"), entries(3))
    assert_equal "Still open. 5d, assigned to @UFF2.", line
  end

  test "an unassigned case says so rather than naming nobody" do
    assert_match(/still unassigned/, timeline_standing(kase, entries(2)))
  end

  test "a resolved case states its outcome" do
    line = timeline_standing(
      kase(resolved_at: Time.utc(2026, 3, 4, 12), resolution: "action_taken"), entries(6)
    )
    assert_equal "Resolved 4 Mar as action taken.", line
  end

  test "an empty timeline says nothing has happened" do
    assert_equal "Nothing has happened on this case yet.", timeline_standing(kase, [])
  end

  test "one subject reads as a handle" do
    assert_equal "@UAAA", subject_handles(make_case(subject: "UAAA"))
  end

  test "several subjects name the first and count the rest" do
    saved = make_case(subject: "UAAA")
    saved.add_subject!("UBBB")
    assert_equal "@UAAA and 1 other", subject_handles(Fd::Case.find(saved.id))

    saved.add_subject!("UCCC")
    assert_equal "@UAAA and 2 others", subject_handles(Fd::Case.find(saved.id))
  end

  test "a case about nobody says so rather than naming an empty handle" do
    assert_equal "no subject set", subject_handles(make_case(subject: nil))
  end
end
