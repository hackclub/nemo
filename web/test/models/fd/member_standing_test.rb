require "test_helper"

class Fd::MemberStandingTest < ActiveSupport::TestCase
  SUBJECT = "USTAND".freeze

  def standing(user_id = SUBJECT, at: Time.current)
    Fd::MemberStanding.new(Fd::MemberRecord.new(user_id), at: at)
  end

  def hold(**attrs)
    Fd::MemberGuard.create!({ kind: "shush", subject_id: SUBJECT, opened_by: "UFF1",
                              reason: "being awful", expires_at: 3.days.from_now,
                              opened_at: 2.days.ago }.merge(attrs))
  end

  def act_on(kase, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: SUBJECT,
                         decided_by: "UFF1", performed_by: "UFF1",
                         performed_at: 2.days.ago }.merge(attrs))
  end

  test "somebody with nothing on them is clean" do
    said = standing("UNOBODY")

    assert said.clean?
    assert_equal 0, said.priors
    assert_empty said.in_force
    assert_nil said.worst
    assert_nil said.open_case
    assert_not said.anything_in_force?
  end

  test "a case with no action still counts as something, not clean" do
    make_case(subject: SUBJECT)
    assert_not standing.clean?
  end

  test "a live guard is in force and is the worst of one" do
    hold

    said = standing
    assert said.anything_in_force?
    assert_equal 1, said.in_force.size
    assert_equal "shush", said.worst.kind
    assert_equal said.worst.expires_at, said.lifts_at
  end

  test "a guard with no end date is still in force, unlike an action" do
    hold(expires_at: nil)

    said = standing
    assert said.anything_in_force?
    assert_nil said.lifts_at
  end

  test "an action that has not expired is no longer standing on its own" do
    kase = make_case(subject: SUBJECT)
    act_on(kase, type_key: "shush", expires_at: 3.days.from_now)

    said = standing
    assert_empty said.in_force, "nothing holds it in Slack, so nothing is in force"
    assert_equal 1, said.actions
  end

  test "a lifted guard is not in force" do
    hold(state: "lifted", lifted_at: Time.current, lifted_by: "UFF1")

    assert_empty standing.in_force
    assert_not standing.anything_in_force?
  end

  test "a guard still being lifted is still in force" do
    hold(state: "lifting", lifted_by: "UFF1")

    assert standing.anything_in_force?
  end

  test "a reversed action is still counted as reversed" do
    kase = make_case(subject: SUBJECT)
    act_on(kase, reversed_at: Time.current, reversed_by: "UFF1", reversal_reason: "wrong person")

    said = standing
    assert_empty said.in_force
    assert_equal 1, said.reversed
    assert_equal 1, said.actions
  end

  test "the worst thing in force wins, whatever order it was held in" do
    hold(kind: "shush", opened_at: 2.hours.ago, expires_at: 5.days.from_now)
    hold(kind: "channel_ban", channel_id: "C0266FRGV", opened_at: 3.days.ago,
         expires_at: 9.days.from_now)

    said = standing
    assert_equal 2, said.in_force.size
    assert_equal "channel_ban", said.worst.kind, "a channel ban outranks a shush"
    assert_equal said.worst.expires_at, said.lifts_at
  end

  test "the newest wins when two of the same kind are in force" do
    old = hold(kind: "channel_ban", channel_id: "COLD", opened_at: 10.days.ago)
    fresh = hold(kind: "channel_ban", channel_id: "CNEW", opened_at: 1.day.ago)

    assert_equal fresh.id, standing.worst.id
    assert_not_equal old.id, standing.worst.id
  end

  test "an open case is named, with whoever holds it" do
    kase = make_case(subject: SUBJECT, assign: "UFF1")

    said = standing
    assert_equal kase.id, said.open_case.id
    assert_equal "UFF1", said.held_by
  end

  test "a case nobody holds has no holder" do
    make_case(subject: SUBJECT)
    assert_nil standing.held_by
  end

  test "a resolved case is not the open one" do
    make_case(subject: SUBJECT, resolved_at: Time.current, resolution: "no_action")

    assert_nil standing.open_case
  end

  test "the counts split what they were the subject of from what they were only logged in" do
    subject_case = make_case(subject: SUBJECT)
    other = make_case(subject: "USOMEBODY")
    other.participants.create!(user_id: SUBJECT, role: "reporter")

    said = standing
    assert_equal 1, said.cases
    assert_equal 1, said.logged_in
    assert_not_equal subject_case.id, other.id
  end

  test "priors come from the twelve month window, not from every case ever" do
    old = make_case(subject: SUBJECT, opened_at: 3.years.ago, resolved_at: 3.years.ago,
      resolution: "action_taken")
    act_on(old, performed_at: 3.years.ago)

    recent = make_case(subject: SUBJECT, opened_at: 2.months.ago, resolved_at: 1.month.ago,
      resolution: "action_taken")
    act_on(recent, performed_at: 2.months.ago)

    assert_equal 1, standing.priors
  end
end
