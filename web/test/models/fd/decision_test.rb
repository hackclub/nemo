require "test_helper"

class Fd::DecisionTest < ActiveSupport::TestCase
  def write(**attrs)
    Fd::Decision.create!({
      title: "Spam accounts",
      statement: "A first-post account posting an invite link is banned on sight.",
      proposed_by: "UFF1"
    }.merge(attrs))
  end

  def settled(**attrs)
    decision = write(**attrs)
    decision.settle!(by: "ULEAD")
    decision
  end

  test "a decision starts proposed, and nobody has settled it" do
    decision = write

    assert_predicate decision, :proposed?
    assert_nil decision.settled_at
    assert_nil decision.settled_by
  end

  test "settling stamps who agreed and when" do
    decision = write
    decision.settle!(by: "ULEAD", at: Time.utc(2026, 8, 2, 12))

    assert_predicate decision, :settled?
    assert_equal "ULEAD", decision.settled_by
    assert_equal Time.utc(2026, 8, 2, 12), decision.settled_at
  end

  test "settling twice is refused, so the first agreement stands" do
    decision = settled

    assert_raises(Fd::Decision::NotAllowed) { decision.settle!(by: "UOTHER") }
    assert_equal "ULEAD", decision.reload.settled_by
  end

  test "superseding retires the old one and points it at what replaced it" do
    old = settled
    new = settled(title: "Spam accounts, with a carve-out")
    old.supersede!(new, by: "ULEAD", at: Time.utc(2026, 8, 16))

    assert_predicate old, :superseded?
    assert_equal new.id, old.replaced_by_id
    assert_equal new, old.replacement
    assert_equal "ULEAD", old.retired_by
    assert_equal [old], new.replaced.to_a
  end

  test "a decision cannot supersede itself" do
    decision = settled

    assert_raises(Fd::Decision::NotAllowed) { decision.supersede!(decision, by: "ULEAD") }
    assert_predicate decision.reload, :settled?
  end

  test "a proposed decision cannot be superseded, it has never been the rule" do
    old = write
    new = settled(title: "Something else")

    assert_raises(Fd::Decision::NotAllowed) { old.supersede!(new, by: "ULEAD") }
  end

  test "a retired decision cannot replace anything" do
    old = settled
    dead = settled(title: "Warnings by DM")
    replacement = settled(title: "Something newer")
    dead.supersede!(replacement, by: "ULEAD")

    assert_raises(Fd::Decision::NotAllowed) { old.supersede!(dead, by: "ULEAD") }
  end

  test "amending changes the wording only while it is in force" do
    decision = settled
    decision.amend!(statement: "Banned on sight, unless they have any history.")

    assert_equal "Banned on sight, unless they have any history.", decision.reload.statement
    assert_predicate decision, :settled?
  end

  test "a proposed decision is edited, not amended" do
    decision = write

    assert_raises(Fd::Decision::NotAllowed) { decision.amend!(statement: "something else") }
  end

  test "amending cannot move the state or rewrite who settled it" do
    decision = settled
    decision.amend!(statement: "reworded", state: "proposed", settled_by: "UME")

    assert_predicate decision.reload, :settled?
    assert_equal "ULEAD", decision.settled_by
  end

  test "a proposed decision can be dropped, a settled one cannot" do
    proposal = write
    proposal.drop!
    assert_not Fd::Decision.exists?(proposal.id)

    decision = settled
    assert_raises(Fd::Decision::NotAllowed) { decision.drop! }
    assert Fd::Decision.exists?(decision.id)
  end

  test "reasons drop the blank lines rather than storing them" do
    decision = write(reasons: ["  it is abandoned within the hour  ", "", "   ", "and it is cheap to reverse"])

    assert_equal ["it is abandoned within the hour", "and it is cheap to reverse"], decision.reasons
  end

  test "a title with stray whitespace is stored trimmed" do
    assert_equal "Night shift", write(title: "  Night shift\n").title
  end

  test "the log separates what is in force from what is proposed and retired" do
    proposal = write(title: "Appeals")
    rule = settled(title: "Pile-ons")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    assert_equal [rule], Fd::Decision.in_force.to_a
    assert_equal [proposal], Fd::Decision.unsettled.to_a
    assert_equal [dead], Fd::Decision.retired.to_a
    assert_equal [proposal, rule].map(&:id).sort, Fd::Decision.live.ids.sort
  end

  test "the log reads in the order the decisions took effect" do
    first = settled(title: "Pile-ons", proposed_at: 3.months.ago)
    first.update!(settled_at: 2.months.ago)
    second = settled(title: "Night shift", proposed_at: 2.days.ago)
    second.update!(settled_at: 1.day.ago)
    waiting = write(title: "Appeals", proposed_at: 1.hour.ago)

    assert_equal [first, second, waiting], Fd::Decision.oldest_first.to_a
    assert_equal [waiting, second, first], Fd::Decision.newest_first.to_a
  end

  test "a decision carries the threads it was argued in, oldest first" do
    decision = settled
    late = decision.threads.create!(channel_id: "C1", thread_ts: "2.2",
      added_by: "UFF1", added_at: 1.hour.ago, why: "the objection")
    early = decision.threads.create!(channel_id: "C1", thread_ts: "1.1",
      added_by: "UFF1", added_at: 2.days.ago, why: "  where it was decided  ")

    assert_equal [early, late], decision.threads.to_a
    assert_equal "where it was decided", early.why
    assert_equal ["C1", "1.1"], early.coordinates
  end

  test "a thread linked without a reason keeps nothing rather than blank text" do
    thread = settled.threads.create!(channel_id: "C1", thread_ts: "1.1",
      added_by: "UFF1", why: "   ")

    assert_nil thread.why
    assert_not thread.said_why?
  end

  test "a category reads as the same label a case uses" do
    assert_equal "Spam", write(category_key: "spam").category_label
    assert_nil write(title: "Night shift").category_label
  end

  test "decisions are audited under their own entity types" do
    decision = settled
    thread = decision.threads.create!(channel_id: "C1", thread_ts: "1.1", added_by: "UFF1")

    assert_equal "decision", Fd::Audit.entity_type(decision)
    assert_equal "decision_thread", Fd::Audit.entity_type(thread)
  end
end
