require "test_helper"

class FdActionSettleTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    @kase = make_case(opened_at: 3.days.ago)
  end

  def guard!(**over)
    Fd::MemberGuard.create!({
      kind: "shush", subject_id: "USUB", opened_by: "UMOD",
      reason: "being awful", expires_at: 7.days.from_now
    }.merge(over))
  end

  def act(**params)
    post fd_case_actions_path(@kase), params: {
      type_key: "shush", target_user_id: "USUB", reason: "would not let it go",
      expires_on: 7.days.from_now.to_date.to_s
    }.merge(params)
  end

  def guards = Fd::MemberGuard.for_subject("USUB")

  def logged = @kase.actions.order(:id).last

  def told(verb)
    Fd::AuditEntry.where(entity_type: "member_guard", verb: verb)
  end

  test "a new action is always enforced, nothing is asked" do
    act
    guard = guards.sole
    assert_equal "shush", guard.kind
    assert_equal @kase.id, guard.case_id
    assert_equal "nemo", guard.carried_by
    assert_equal "pending", guard.carry
    assert_equal guard.id, logged.guard_id
    assert_equal 1, told("opened").count
  end

  test "a record only kind is logged without enforcing anything" do
    act(type_key: "warning", expires_on: nil)
    assert_empty guards
    assert_nil logged.guard_id
    assert_equal "warning", logged.type_key
  end

  test "a workspace kind is enforced without the channel it was handed" do
    act(channel_id: "C0266FRGV")
    assert_nil guards.sole.channel_id
  end

  test "a channel ban is enforced in the channel it names" do
    act(type_key: "channel_ban", channel_id: "C0266FRGV")
    assert_equal "C0266FRGV", guards.sole.channel_id
  end

  test "choosing one already standing attaches it and logs it, without a second guard" do
    held = guard!
    act(standing_guard_id: held.id)

    assert_equal @kase.id, held.reload.case_id
    assert_equal 1, guards.count
    assert_equal held.id, logged.guard_id
    assert_equal "shush", logged.type_key
    assert_equal 1, told("attached").count
    assert_empty told("opened")
  end

  test "the logged action takes its shape from the guard, not the form" do
    held = guard!(kind: "channel_ban", channel_id: "C0266FRGV",
      reason: "off topic", expires_at: 30.days.from_now)
    act(standing_guard_id: held.id, type_key: "warning", reason: "something else")

    assert_equal "channel_ban", logged.type_key
    assert_equal "off topic", logged.reason
    assert_equal "C0266FRGV", logged.details["channel_id"]
    assert_equal held.expires_at.to_i, logged.expires_at.to_i
  end

  test "choosing one already on another case links it without moving it" do
    other = make_case
    held = guard!(case_id: other.id)
    act(standing_guard_id: held.id)

    assert_equal other.id, held.reload.case_id, "it is not stolen from its case"
    assert_equal held.id, logged.guard_id
    assert_empty told("attached")
  end

  test "choosing one already on this case is refused, not logged again" do
    held = guard!(case_id: @kase.id)
    act(standing_guard_id: held.id)

    assert_equal 0, @kase.actions.count
    assert_empty told("attached")
    assert_match(/already on this case/, flash[:alert])
  end

  test "choosing one needs none of the fields the form would otherwise want" do
    held = guard!
    act(standing_guard_id: held.id, type_key: "", reason: "", expires_on: "")

    assert_equal held.id, logged.guard_id
    assert_equal 1, @kase.actions.count
  end

  test "a guard standing on somebody else cannot be attached" do
    held = guard!(subject_id: "USOMEBODY")
    act(standing_guard_id: held.id)

    assert_nil held.reload.case_id
    assert_equal "shush", logged.type_key, "it falls through to logging a new one"
    assert_not_equal held.id, logged.guard_id
  end

  test "a lifted guard cannot be attached" do
    held = guard!(state: "lifted", lifted_at: Time.current, lifted_by: "UMOD")
    act(standing_guard_id: held.id)

    assert_nil held.reload.case_id
    assert_not_equal held.id, logged.guard_id
  end

  test "a second action of the same kind cannot open a second guard" do
    guard!(case_id: @kase.id)
    act
    assert_equal 1, guards.count
  end

  test "nothing is written at all when the action itself is refused" do
    drop_roles!("UME")
    hold_role!("UME", "gardener")
    act
    assert_empty guards
    assert_empty @kase.actions
  end

  test "a guard held by another case is logged here once, not twice" do
    other = make_case
    guard = guard!(case_id: other.id)
    act(standing_guard_id: guard.id)
    act(standing_guard_id: guard.id)

    assert_equal 1, @kase.actions.count
    assert_equal other.id, guard.reload.case_id
    assert_match(/already logged on this case/, flash[:alert])
  end

  test "an orphaned guard is attached once, then refused" do
    guard = guard!(case_id: nil)
    act(standing_guard_id: guard.id)
    act(standing_guard_id: guard.id)

    assert_equal 1, @kase.actions.count
    assert_equal @kase.id, guard.reload.case_id
    assert_match(/already on this case/, flash[:alert])
  end
end
