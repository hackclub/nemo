require "test_helper"

class Fd::PriorsTest < ActiveSupport::TestCase
  SUBJECT = "UPRIOR".freeze

  def resolved_case(opened:, resolved:, resolution: "action_taken", subject: SUBJECT)
    make_case(subject: subject, opened_at: opened, resolved_at: resolved, resolution: resolution)
  end

  def act_on(kase, target: SUBJECT, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: target,
                         decided_by: "UFF1", performed_by: "UFF1",
                         performed_at: kase.resolved_at || kase.opened_at }.merge(attrs))
  end

  test "a resolved case with an action against them is a prior" do
    act_on resolved_case(opened: 60.days.ago, resolved: 50.days.ago)
    assert_equal 1, Fd::Case.prior_count(SUBJECT)
  end

  test "an action counts as a prior even while its case is still open" do
    act_on make_case(subject: SUBJECT, opened_at: 3.days.ago)
    assert_equal 1, Fd::Case.prior_count(SUBJECT),
      "a prior is an action taken against them, not a case that happens to have closed"
  end

  test "an open case with no action against them is still not a prior" do
    make_case(subject: SUBJECT, opened_at: 3.days.ago)
    assert_equal 0, Fd::Case.prior_count(SUBJECT),
      "an accusation on its own must not count against anybody"
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

  test "an action logged against somebody else on their case is not their prior" do
    act_on resolved_case(opened: 60.days.ago, resolved: 50.days.ago), target: "UELSE"
    assert_equal 0, Fd::Case.prior_count(SUBJECT),
      "a case about two people, acted on for one of them, is a prior for that one only"
  end

  test "a reversed action is not a prior, because it was undone" do
    act_on resolved_case(opened: 60.days.ago, resolved: 50.days.ago),
      reversed_at: 40.days.ago, reversed_by: "UFF2", reversal_reason: "appeal upheld"

    assert_equal 0, Fd::Case.prior_count(SUBJECT),
      "reversing an action says it should not have happened, so it cannot count as a finding"
  end

  test "one live action among reversed ones still makes a prior" do
    kase = resolved_case(opened: 60.days.ago, resolved: 50.days.ago)
    act_on kase, reversed_at: 40.days.ago, reversed_by: "UFF2", reversal_reason: "appeal upheld"
    act_on kase, type_key: "shush"

    assert_equal 1, Fd::Case.prior_count(SUBJECT)
  end

  test "the window is measured from the moment being asked about, not from today" do
    act_on resolved_case(opened: 20.months.ago, resolved: 19.months.ago)
    later = make_case(subject: SUBJECT, opened_at: 8.months.ago)

    assert_equal 0, Fd::Case.prior_count(SUBJECT, within: Fd::Case::PRIOR_WINDOW),
      "19 months ago is outside a year from today"
    assert_equal 1, Fd::Case.prior_count(SUBJECT, within: Fd::Case::PRIOR_WINDOW,
      before: later.opened_at), "but it was inside a year when that case was opened"
  end

  test "the window is measured from when the action was taken" do
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

  test "the members list counts the same priors the member page does" do
    act_on resolved_case(opened: 60.days.ago, resolved: 50.days.ago)
    act_on resolved_case(opened: 20.months.ago, resolved: 19.months.ago)

    row = Fd::MemberQuery.new({}).summary_rows.find { |found| found.user_id == SUBJECT }
    assert_equal Fd::Case.prior_count(SUBJECT, within: Fd::Case::PRIOR_WINDOW), row.priors,
      "the list and the record must not answer the same question differently"
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
