require "test_helper"

class Fd::CaseAssigneeTest < ActiveSupport::TestCase
  setup do
    @mine = make_case
    @theirs = make_case
    @nobodys = make_case
  end

  def ours
    Fd::Case.where(id: [@mine.id, @theirs.id, @nobodys.id])
  end

  test "a case nobody has taken reads as unassigned" do
    assert_not @nobodys.assigned?
    assert_empty @nobodys.assignee_user_ids
  end

  test "assigning records who did it, not only who it went to" do
    @mine.assign!("UME")
    person = @mine.assignees.sole

    assert_equal "UME", person.user_id
    assert_equal "UME", person.assigned_by
    assert_not_nil person.assigned_at
  end

  test "one firefighter can put a case on another" do
    @mine.assign!("UTHEM", by: "UME")
    assert_equal "UME", @mine.assignees.sole.assigned_by
  end

  test "a case can be on several people at once" do
    @mine.assign!("UONE")
    @mine.assign!("UTWO")

    assert_equal %w[UONE UTWO], @mine.reload.assignee_user_ids
    assert @mine.assigned_to?("UTWO")
    assert_not @mine.assigned_to?("USOMEBODY")
  end

  test "the same person twice is refused by the key, not silently doubled" do
    @mine.assign!("UONE")
    assert_raises(ActiveRecord::RecordNotUnique) { @mine.assign!("UONE") }
  end

  test "assigned_to finds every case somebody is on" do
    @mine.assign!("UME")
    @theirs.assign!("UOTHER")

    assert_equal [@mine.id], ours.assigned_to("UME").ids
    assert_equal [@theirs.id], ours.assigned_to("UOTHER").ids
  end

  test "unassigned excludes cases that are on somebody, and keeps the rest" do
    @mine.assign!("UME")
    @theirs.assign!("UOTHER")

    assert_equal [@nobodys.id], ours.unassigned.ids
  end

  test "taking somebody off puts the case back in the queue" do
    @mine.assign!("UME")
    @mine.assignees.sole.destroy!

    assert_not @mine.reload.assigned?
    assert_includes ours.unassigned.ids, @mine.id
  end

  test "assignees come back oldest first, so the first to take it reads first" do
    @mine.assignees.create!(user_id: "ULATE", assigned_by: "ULATE", assigned_at: 1.hour.ago)
    @mine.assignees.create!(user_id: "UEARLY", assigned_by: "UEARLY", assigned_at: 3.hours.ago)

    assert_equal %w[UEARLY ULATE], @mine.reload.assignee_user_ids
  end
end
