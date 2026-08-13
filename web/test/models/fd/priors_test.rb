require "test_helper"

class Fd::PriorsTest < ActiveSupport::TestCase
  SUBJECT = "UPRIOR".freeze

  def resolved_case(opened:, resolved:, resolution: "action_taken", subject: SUBJECT)
    make_case(subject: subject, opened_at: opened, resolved_at: resolved, resolution: resolution)
  end

  def act_on(kase, target: SUBJECT, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: target,
                         decided_by: "UFF1", performed_by: "UFF1" }.merge(attrs))
  end

  test "a resolved case with an action against them is a prior" do
    act_on resolved_case(opened: 60.days.ago, resolved: 50.days.ago)
    assert_equal 1, Fd::Case.prior_count(SUBJECT)
  end

  test "an open case is not a prior, however bad it looks" do
    act_on make_case(subject: SUBJECT, opened_at: 3.days.ago)
    assert_equal 0, Fd::Case.prior_count(SUBJECT),
      "nothing has been decided, so an accusation must not count as a finding"
  end

  test "a resolved case with no action logged is not a prior" do
    resolved_case(opened: 60.days.ago, resolved: 50.days.ago, resolution: "no_action")
    assert_equal 0, Fd::Case.prior_count(SUBJECT)
  end

  test "a case they were only logged in is not a prior" do
    theirs = make_case(subject: "USOMEBODY", opened_at: 60.days.ago,
      resolved_at: 50.days.ago, resolution: "action_taken")
    theirs.participants.create!(user_id: SUBJECT, role: "involved", detail: "it was aimed at them")
    act_on theirs, target: "USOMEBODY"

    assert_equal 0, Fd::Case.prior_count(SUBJECT),
      "being harmed by somebody else must not count against you"
  end

  test "an action logged against somebody else on their case still counts" do
    act_on resolved_case(opened: 60.days.ago, resolved: 50.days.ago), target: "UELSE"
    assert_equal 1, Fd::Case.prior_count(SUBJECT),
      "the case is the unit, and it was resolved with an action on it"
  end

  test "a reversed action still counts, per the definition as written" do
    act_on resolved_case(opened: 60.days.ago, resolved: 50.days.ago),
      reversed_at: 40.days.ago, reversed_by: "UFF2", reversal_reason: "appeal upheld"

    assert_equal 1, Fd::Case.prior_count(SUBJECT)
  end

  test "the window is measured from when the case was resolved" do
    act_on resolved_case(opened: 20.months.ago, resolved: 19.months.ago)
    act_on resolved_case(opened: 3.months.ago, resolved: 2.months.ago)

    assert_equal 2, Fd::Case.prior_count(SUBJECT)
    assert_equal 1, Fd::Case.prior_count(SUBJECT, within: Fd::Case::PRIOR_WINDOW)
  end

  test "priors can be counted as they stood at a moment, for the record" do
    act_on resolved_case(opened: 60.days.ago, resolved: 50.days.ago)
    later = make_case(subject: SUBJECT, opened_at: 10.days.ago)

    assert_equal 1, Fd::Case.prior_count(SUBJECT, before: later.opened_at)
    assert_equal 0, Fd::Case.prior_count(SUBJECT, before: 55.days.ago)
  end

  test "somebody with a clean record counts zero rather than failing" do
    assert_equal 0, Fd::Case.prior_count("UNOBODY")
    assert_empty Fd::Case.priors_for("UNOBODY").to_a
  end

  test "priors_for hands back the cases, so a page can name them" do
    first = resolved_case(opened: 60.days.ago, resolved: 50.days.ago)
    act_on first

    assert_equal [first.id], Fd::Case.priors_for(SUBJECT).ids
  end

  test "one case with two actions is one prior, not two" do
    kase = resolved_case(opened: 60.days.ago, resolved: 50.days.ago)
    act_on kase
    act_on kase, type_key: "shush"

    assert_equal 1, Fd::Case.prior_count(SUBJECT)
  end
end
