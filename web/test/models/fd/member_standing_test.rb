require "test_helper"

class Fd::MemberStandingTest < ActiveSupport::TestCase
  SUBJECT = "USTAND".freeze

  def standing(user_id = SUBJECT, at: Time.current)
    Fd::MemberStanding.new(Fd::MemberRecord.new(user_id), at: at)
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

  test "a live action is in force and is the worst of one" do
    kase = make_case(subject: SUBJECT)
    act_on(kase, type_key: "shush", expires_at: 3.days.from_now)

    said = standing
    assert said.anything_in_force?
    assert_equal 1, said.in_force.size
    assert_equal "shush", said.worst.type_key
    assert_equal said.worst.expires_at, said.lifts_at
  end

  test "an action with no due date is not in force, however serious" do
    kase = make_case(subject: SUBJECT)
    act_on(kase, type_key: "perma_ban", performed_at: 1.day.ago)

    said = standing
    assert_empty said.in_force, "a permanent ban has no due date to reach"
    assert_equal 1, said.actions
  end

  test "an action past its expiry is not in force" do
    kase = make_case(subject: SUBJECT)
    act_on(kase, type_key: "shush", expires_at: 1.day.ago)

    assert_empty standing.in_force
    assert_not standing.anything_in_force?
  end

  test "an action is in force right up to the moment it lifts" do
    kase = make_case(subject: SUBJECT)
    lifts = 1.hour.from_now
    act_on(kase, type_key: "temp_ban", expires_at: lifts)

    assert standing(at: lifts - 1.minute).anything_in_force?
    assert_not standing(at: lifts).anything_in_force?
  end

  test "a reversed action is not in force, but is still counted as reversed" do
    kase = make_case(subject: SUBJECT)
    act_on(kase, reversed_at: Time.current, reversed_by: "UFF1", reversal_reason: "wrong person")

    said = standing
    assert_empty said.in_force
    assert_equal 1, said.reversed
    assert_equal 1, said.actions
  end

  test "the worst thing in force wins, whatever order they were logged in" do
    kase = make_case(subject: SUBJECT)
    act_on(kase, type_key: "warning", performed_at: 1.hour.ago)
    act_on(kase, type_key: "perma_ban", performed_at: 3.days.ago)
    act_on(kase, type_key: "shush", performed_at: 2.hours.ago, expires_at: 5.days.from_now)
    act_on(kase, type_key: "temp_ban", performed_at: 3.days.ago, expires_at: 9.days.from_now)

    said = standing
    assert_equal 2, said.in_force.size, "only a due date not yet reached counts as in force"
    assert_equal "temp_ban", said.worst.type_key, "a ban outranks a shush"
    assert_equal said.worst.expires_at, said.lifts_at
  end

  test "the newest wins when two of the same kind are in force" do
    kase = make_case(subject: SUBJECT)
    old = act_on(kase, type_key: "shush", performed_at: 10.days.ago, expires_at: 2.days.from_now)
    new = act_on(kase, type_key: "shush", performed_at: 1.day.ago, expires_at: 5.days.from_now)

    assert_equal new.id, standing.worst.id
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
    other.participants.create!(user_id: SUBJECT, role: "involved", detail: "aimed at them")

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
