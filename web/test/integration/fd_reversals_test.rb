require "test_helper"

class FdReversalsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
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

  test "a signed out visitor cannot reverse anything" do
    reverse
    assert_redirected_to login_path
    assert_nil @action.reload.reversed_at
  end

  test "reversing records who and why, and deletes nothing" do
    sign_in_as(@me)
    reverse(reversal_reason: "issued against the wrong account")

    @action.reload
    assert_not_nil @action.reversed_at
    assert_equal "UME", @action.reversed_by
    assert_equal "issued against the wrong account", @action.reversal_reason
    assert_equal "temp_ban", @action.type_key, "the action itself must survive"
    assert_equal 1, @kase.actions.count
  end

  test "the paired columns move together, as the constraint requires" do
    sign_in_as(@me)
    reverse
    @action.reload
    assert_equal @action.reversed_at.nil?, @action.reversed_by.nil?
  end

  test "a reversal without a reason is refused" do
    sign_in_as(@me)
    reverse(reversal_reason: "   ")

    assert_nil @action.reload.reversed_at
    assert_nil flash[:alert], "a problem with one field is not a page-level message"
    assert_equal "reversal_reason", flash[:wrong]["field"]
    assert_match(/Say why it is being reversed/i, flash[:wrong]["said"])

    follow_redirect!
  end

  test "an absurdly long reason is refused" do
    sign_in_as(@me)
    reverse(reversal_reason: "x" * (Fd::ReversalsController::MAX_REASON + 1))
    assert_nil @action.reload.reversed_at
    assert_match(/Keep it under 500 characters/, flash[:wrong]["said"])
  end

  test "an action on another case cannot be reversed through this one" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    theirs = Fd::Action.create!(case_id: other.id, type_key: "warning", target_user_id: "UELSE",
      decided_by: "UFF1", performed_by: "UFF1", performed_at: 1.hour.ago, source_app: "fire_engine")

    sign_in_as(@me)
    reverse(action_id: theirs.id)

    assert_nil theirs.reload.reversed_at, "the case in the url must own the action"
    assert_match(/not on this case/, flash[:alert])
  end

  test "reversing twice keeps the first reversal and writes one trail entry" do
    sign_in_as(@me)
    reverse(reversal_reason: "first reason")
    first = @action.reload.reversed_at

    reverse(reversal_reason: "second reason")
    @action.reload

    assert_equal first, @action.reversed_at
    assert_equal "first reason", @action.reversal_reason
    assert_equal 1, entries.count
  end

  test "I can reverse on a case assigned to somebody else" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    reverse

    assert_not_nil @action.reload.reversed_at
  end

  test "the trail keeps the reason, which is not a member note" do
    sign_in_as(@me)
    reverse(reversal_reason: "lifted early after a conversation")

    entry = entries.sole
    assert_equal "UME", entry.after["reversed_by"]
    assert_equal "lifted early after a conversation", entry.after["reason"]
  end

  test "a reversal with no action says so instead of silently doing nothing" do
    sign_in_as(@me)
    reverse(action_id: "")

    assert_redirected_to fd_case_path(@kase, tab: "actions")
    assert_equal "pick the action to reverse", flash[:alert]
    assert_nil @action.reload.reversed_at
  end

  def entries
    Fd::AuditEntry.where(entity_type: "action", entity_id: @action.id, verb: "reversed")
  end
end
