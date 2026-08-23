require "test_helper"

class Fd::CaseFamilyTest < ActiveSupport::TestCase
  def fold(kase, into:)
    kase.update!(resolved_at: Time.current, resolution: "duplicate", duplicate_of: into.id)
    kase
  end

  test "a case on its own is its whole family" do
    kase = make_case

    assert_equal [kase.id], kase.family_ids
    assert_empty kase.merged_in
    assert_not kase.merged?
    assert_not kase.folded?
    assert_equal kase.id, kase.root.id
  end

  test "a root holds every case folded into it, oldest first" do
    root = make_case(opened_at: 10.days.ago)
    first = fold(make_case(opened_at: 8.days.ago), into: root)
    second = fold(make_case(opened_at: 5.days.ago), into: root)

    assert_equal [root.id, first.id, second.id].sort, root.family_ids.sort
    assert_equal [first.id, second.id], root.merged_in.map(&:id)
    assert root.merged?
  end

  test "a folded case knows it is folded, and where it went" do
    root = make_case(opened_at: 10.days.ago)
    folded = fold(make_case(opened_at: 2.days.ago), into: root)

    assert folded.folded?
    assert_equal root.id, folded.root.id
    assert_equal [folded.id], folded.family_ids, "a folded case holds nothing itself"
  end

  test "a case folded into a case that was later folded is still in the family" do
    root = make_case(opened_at: 20.days.ago)
    middle = make_case(opened_at: 10.days.ago)
    leaf = fold(make_case(opened_at: 5.days.ago), into: middle)
    fold(middle, into: root)

    assert_includes root.family_ids, middle.id
    assert_includes root.family_ids, leaf.id, "the chain is followed, not just one hop"
    assert_equal 3, root.family_ids.size
    assert_equal [middle.id, leaf.id], root.merged_in.map(&:id)
  end

  test "the family never includes the same case twice" do
    root = make_case(opened_at: 10.days.ago)
    fold(make_case(opened_at: 5.days.ago), into: root)

    assert_equal root.family_ids.uniq, root.family_ids
  end

  test "a loop cannot hang the walk" do
    one = make_case(opened_at: 10.days.ago)
    two = make_case(opened_at: 5.days.ago)
    one.update_columns(duplicate_of: two.id)
    two.update_columns(duplicate_of: one.id)

    assert_equal 2, Fd::Case.family_of(one.id).size
    assert_includes [one.id, two.id], one.root.id
  end

  test "family_of takes a bare id, for callers that have no record" do
    root = make_case(opened_at: 10.days.ago)
    folded = fold(make_case(opened_at: 2.days.ago), into: root)

    assert_equal [root.id, folded.id].sort, Fd::Case.family_of(root.id).sort
  end

  test "somebody else's duplicate is not in this family" do
    root = make_case(opened_at: 10.days.ago)
    other = make_case(opened_at: 9.days.ago)
    fold(make_case(opened_at: 2.days.ago), into: other)

    assert_equal [root.id], root.family_ids
  end
end
