require "test_helper"

class Fd::CasePersonTest < ActiveSupport::TestCase
  setup do
    @kase = make_case(subject: "UDEX", opened_at: 2.days.ago)
    @person = Fd::CasePeople.for(@kase.participants.to_a).chosen
  end

  def build(actions: [], notes: [])
    Fd::CasePerson.for(@person, kase: @kase, actions: actions, notes: notes)
  end

  def action(target:, **attrs)
    Fd::Action.create!({ case_id: @kase.id, type_key: "warning", target_user_id: target,
      decided_by: "UFF1", performed_by: "UFF1", performed_at: 1.day.ago }.merge(attrs))
  end

  def note(body)
    Fd::Note.create!(case_id: @kase.id, body: body, author: "UFF1")
  end

  test "only actions aimed at this person count" do
    mine = action(target: "UDEX")
    action(target: "UOTHER")

    assert_equal [mine.id], build(actions: Fd::Action.oldest_first.to_a).actions.map(&:id)
  end

  test "a reversed action is still listed, and counted apart" do
    action(target: "UDEX", reversed_at: 1.hour.ago, reversed_by: "UFF2")
    here = build(actions: Fd::Action.oldest_first.to_a)

    assert_equal 1, here.actions.size
    assert_equal 1, here.reversed_actions
    assert_empty here.live_actions
  end

  test "a note counts as naming them only if it mentions them" do
    about = note("spoke to <@UDEX> about it")
    note("nothing to do with them")
    here = build(notes: Fd::Note.where(case_id: @kase.id).to_a)

    assert_equal [about.id], here.notes_naming.map(&:id)
    assert_equal 2, here.notes_total
  end

  test "priors count only cases resolved before this one opened" do
    earlier = make_case(subject: "UDEX", opened_at: 60.days.ago)
    earlier.update!(resolved_at: 50.days.ago, resolution: "action_taken")
    Fd::Action.create!(case_id: earlier.id, type_key: "warning", target_user_id: "UDEX",
      decided_by: "UFF1", performed_by: "UFF1", performed_at: 55.days.ago)

    later = make_case(subject: "UDEX", opened_at: 1.day.ago)
    later.update!(resolved_at: Time.current, resolution: "action_taken")
    Fd::Action.create!(case_id: later.id, type_key: "warning", target_user_id: "UDEX",
      decided_by: "UFF1", performed_by: "UFF1", performed_at: 1.hour.ago)

    assert_equal 1, build.priors, "a case resolved after this one opened is not a prior for it"
  end

  test "the rows explain themselves, and agree with the count" do
    counted = make_case(subject: "UDEX", opened_at: 60.days.ago)
    counted.update!(resolved_at: 50.days.ago, resolution: "action_taken")
    action(target: "UDEX", case_id: counted.id, performed_at: 55.days.ago)

    undone = make_case(subject: "UDEX", opened_at: 40.days.ago)
    undone.update!(resolved_at: 30.days.ago, resolution: "action_taken")
    action(target: "UDEX", case_id: undone.id, performed_at: 35.days.ago,
      reversed_at: 20.days.ago, reversed_by: "UFF2", reversal_reason: "appeal upheld")

    nothing = make_case(subject: "UDEX", opened_at: 20.days.ago)
    nothing.update!(resolved_at: 10.days.ago, resolution: "no_action")

    onlooker = make_case(subject: "USOMEBODY", opened_at: 15.days.ago)
    onlooker.update!(resolved_at: 12.days.ago, resolution: "action_taken")
    Fd::CaseParticipant.create!(case_id: onlooker.id, user_id: "UDEX", role: "involved",
      detail: "they were in the thread")
    action(target: "USOMEBODY", case_id: onlooker.id, performed_at: 13.days.ago)

    here = build
    reasons = here.earlier_cases.to_h { |row| [row.kase.id, row.why] }

    assert_nil reasons[counted.id]
    assert_equal "the action was reversed", reasons[undone.id]
    assert_equal "nothing was done to them", reasons[nothing.id]
    assert_equal "logged, not the subject", reasons[onlooker.id]
    assert_equal here.priors, here.earlier_cases.count(&:counts),
      "the number and the rows behind it must never disagree"
  end

  test "cases ever counts every case they appear on, in any role" do
    other = make_case(subject: "USOMEBODY")
    Fd::CaseParticipant.create!(case_id: other.id, user_id: "UDEX", role: "involved",
      detail: "they were in the thread")

    assert_equal 2, build.cases_ever
  end
end
