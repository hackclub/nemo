require "test_helper"

class FdHelperTest < ActionView::TestCase
  include FdHelper

  def kase(**attrs)
    Fd::Case.new({ id: 1, opened_by: "UFF1", opened_at: 5.days.ago }.merge(attrs))
  end

  def entries(count)
    Array.new(count) { Fd::CaseTimeline::Entry.new(at: Time.current, title: "x") }
  end

  test "an open case says it will not age out and who has it" do
    line = timeline_standing(kase(claimed_by: "UFF2", claimed_at: 4.days.ago), entries(3))
    assert_match(/\AStill open\. 5d, assigned to @UFF2\./, line)
    assert_match(/stays here until somebody resolves it/, line)
  end

  test "an unassigned case says so rather than naming nobody" do
    assert_match(/still unassigned/, timeline_standing(kase, entries(2)))
  end

  test "a resolved case states its outcome and entry count" do
    line = timeline_standing(
      kase(resolved_at: Time.utc(2026, 3, 4, 12), resolution: "action_taken"), entries(6)
    )
    assert_match(/\AResolved 4 Mar as action taken\. 6 entries/, line)
  end

  test "an empty timeline says nothing has happened" do
    assert_equal "Nothing has happened on this case yet.", timeline_standing(kase, [])
  end
end
