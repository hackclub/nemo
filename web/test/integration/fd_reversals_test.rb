require "test_helper"

class FdReversalsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    @kase = make_case(opened_at: 3.days.ago)
    @action = make_action
  end

  def make_action(**attrs)
    Fd::Action.create!({
      case_id: @kase.id, type_key: "temp_ban", target_user_id: "USUB",
      decided_by: "UFF1", performed_by: "UFF1", performed_at: 2.days.ago,
      source_app: "fire_engine", expires_at: 30.days.from_now
    }.merge(attrs))
  end

  def reverse(**params)
    post fd_case_reversals_path(@kase), params: {
      action_id: @action.id, reversal_reason: "appeal upheld"
    }.merge(params)
  end

  test "create signed out redirects to login and leaves reversed_at nil" do
    reverse
    assert_redirected_to root_path
    assert_nil @action.reload.reversed_at
  end

  test "create sets reversed_at reversed_by and reversal_reason and keeps the action" do
    sign_in_as(@me)
    reverse(reversal_reason: "issued against the wrong account")

    @action.reload
    assert_not_nil @action.reversed_at
    assert_equal "UME", @action.reversed_by
    assert_equal "issued against the wrong account", @action.reversal_reason
    assert_equal "temp_ban", @action.type_key, "the action itself must survive"
    assert_equal 1, @kase.actions.count
  end

  def make_guard(**attrs)
    Fd::MemberGuard.create!({
      kind: "deactivation", subject_id: "USUB", case_id: @kase.id, opened_by: "UFF1",
      reason: "raiding", enforced_by: "nemo", enforcement_status: "held"
    }.merge(attrs))
  end

  test "create moves a deactivation guard to lifting with lifted_by and lift_reason" do
    sign_in_as(@me)
    guard = make_guard
    @action.update!(guard_id: guard.id)

    reverse(reversal_reason: "appeal upheld")

    guard.reload
    assert_equal Fd::MemberGuard::LIFTING, guard.state, "guard did not move to lifting"
    assert_nil guard.lifted_at, "lifted_at set before the lift completes"
    assert_equal "UME", guard.lifted_by
    assert_match(/appeal upheld/, guard.lift_reason)
  end

  test "create moves a shush guard to lifted with lifted_at set" do
    sign_in_as(@me)
    guard = make_guard(kind: "shush", expires_at: 30.days.from_now)
    @action.update!(guard_id: guard.id)

    reverse

    guard.reload
    assert_equal Fd::MemberGuard::LIFTED, guard.state
    assert_not_nil guard.lifted_at
  end

  test "create keeps a guard live while another live action references it" do
    sign_in_as(@me)
    guard = make_guard
    @action.update!(guard_id: guard.id)
    make_action(guard_id: guard.id)

    reverse

    assert_not_nil @action.reload.reversed_at
    assert_equal Fd::MemberGuard::LIVE, guard.reload.state
  end

  test "create on an action without guard_id sets reversed_at and creates no guard" do
    sign_in_as(@me)
    reverse

    assert_not_nil @action.reload.reversed_at
    assert_equal 0, Fd::MemberGuard.count
  end

  test "create leaves reversed_at and reversed_by both nil or both set" do
    sign_in_as(@me)
    reverse
    @action.reload
    assert_equal @action.reversed_at.nil?, @action.reversed_by.nil?
  end

  test "create with blank reversal_reason sets field_error and leaves reversed_at nil" do
    sign_in_as(@me)
    reverse(reversal_reason: "   ")

    assert_nil @action.reload.reversed_at
    assert_nil flash[:alert], "flash alert set for a field error"
    assert_equal "reversal_reason", flash[:field_error]["field"]
    assert_match(/Enter a reason/i, flash[:field_error]["message"])

    follow_redirect!
  end

  test "create with reversal_reason over MAX_REASON sets field_error" do
    sign_in_as(@me)
    reverse(reversal_reason: "x" * (Fd::ReversalsController::MAX_REASON + 1))
    assert_nil @action.reload.reversed_at
    assert_match(/Keep it under 500 characters/, flash[:field_error]["message"])
  end

  test "create with action_id of another case sets alert and leaves reversed_at nil" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    other_action = Fd::Action.create!(case_id: other.id, type_key: "warning", target_user_id: "UELSE",
      decided_by: "UFF1", performed_by: "UFF1", performed_at: 1.hour.ago, source_app: "fire_engine")

    sign_in_as(@me)
    reverse(action_id: other_action.id)

    assert_nil other_action.reload.reversed_at, "action of another case was reversed"
    assert_match(/Action not found or already reversed/, flash[:alert])
  end

  test "create twice keeps the first reversal and writes one audit entry" do
    sign_in_as(@me)
    reverse(reversal_reason: "first reason")
    first = @action.reload.reversed_at

    reverse(reversal_reason: "second reason")
    @action.reload

    assert_equal first, @action.reversed_at
    assert_equal "first reason", @action.reversal_reason
    assert_equal 1, entries.count
  end

  test "create on a case assigned to another user sets reversed_at" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    reverse

    assert_not_nil @action.reload.reversed_at
  end

  test "create writes an audit entry with reversed_by and reason" do
    sign_in_as(@me)
    reverse(reversal_reason: "lifted early after a conversation")

    entry = entries.sole
    assert_equal "UME", entry.after["reversed_by"]
    assert_equal "lifted early after a conversation", entry.after["reason"]
  end

  test "create with blank action_id redirects to the actions tab with an alert" do
    sign_in_as(@me)
    reverse(action_id: "")

    assert_redirected_to fd_case_path(@kase, tab: "actions")
    assert_equal "Select an action to reverse", flash[:alert]
    assert_nil @action.reload.reversed_at
  end

  def entries
    Fd::AuditEntry.where(entity_type: "action", entity_id: @action.id, verb: "reversed")
  end

  def sign_in_without_deactivate
    sign_in_as(grant_role!("UFF2", "firefighter"))
    override_capability!("firefighter", "member.deactivate", false)
  end

  test "create without member deactivate refuses to reverse a ban holding a deactivation" do
    guard = make_guard
    @action.update!(guard_id: guard.id)
    sign_in_without_deactivate

    reverse

    assert_nil @action.reload.reversed_at
    assert_equal Fd::MemberGuard::LIVE, guard.reload.state
    assert flash[:alert].present?
  end

  test "create without member deactivate reverses a ban whose deactivation another action keeps" do
    guard = make_guard
    @action.update!(guard_id: guard.id)
    make_action(type_key: "perma_ban", expires_at: nil, guard_id: guard.id)
    sign_in_without_deactivate

    reverse

    assert_not_nil @action.reload.reversed_at
    assert_equal Fd::MemberGuard::LIVE, guard.reload.state
  end

  test "create on a deactivation queues the reactivation in the notice" do
    sign_in_as(@me)
    guard = make_guard
    @action.update!(guard_id: guard.id)

    reverse

    assert_equal "Action reversed · reactivation queued", flash[:notice]
  end

  test "reverse button needs member deactivate when the reversal reactivates" do
    guard = make_guard
    @action.update!(guard_id: guard.id)
    sign_in_without_deactivate

    get fd_case_path(@kase, tab: "actions")

    assert_select "button[data-modal-open=?]", "reverse-#{@action.id}", count: 0
  end
end
