require "test_helper"

class FdActionEditsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "firefighter")
    @kase = make_case(opened_at: 3.days.ago)
    @action = Fd::Action.create!(
      case_id: @kase.id, type_key: "warning", target_user_id: "USUB",
      decided_by: "UFF1", performed_by: "UFF1", performed_at: 2.days.ago,
      source_app: "fire_engine", reason: "spamm", category_key: "spam"
    )
  end

  def edit_action(action = @action, **params)
    patch fd_case_action_path(@kase, action), params: {
      reason: "spam in #lounge", category_key: "advertising"
    }.merge(params)
  end

  test "signed out edit redirects to login" do
    edit_action
    assert_redirected_to root_path
    assert_equal "spamm", @action.reload.reason
  end

  test "edit without case act is refused" do
    override_capability!("firefighter", "case.act", false)
    sign_in_as(@me)
    edit_action
    assert_equal "spamm", @action.reload.reason
  end

  test "edit updates reason and category and audits the change" do
    sign_in_as(@me)
    edit_action

    assert_redirected_to fd_case_path(@kase, tab: "actions")
    assert_equal "Action updated", flash[:notice]
    @action.reload
    assert_equal ["spam in #lounge", "advertising"], [@action.reason, @action.category_key]
    assert_nil @action.reversed_at
    entry = Fd::AuditEntry.where(entity_type: "action", entity_id: @action.id, verb: "edited").last
    assert_equal({ "reason" => "spamm", "category_key" => "spam" }, entry.before)
    assert_equal "advertising", entry.after["category_key"]
  end

  test "edit without changes writes no audit entry" do
    sign_in_as(@me)
    edit_action(reason: "spamm", category_key: "spam")

    assert_equal "No changes", flash[:notice]
    assert_not Fd::AuditEntry.exists?(entity_type: "action", entity_id: @action.id, verb: "edited")
  end

  test "edit with blank reason reopens the modal with a field error" do
    sign_in_as(@me)
    edit_action(reason: "  ")

    assert_redirected_to fd_case_path(@kase, tab: "actions", do: "edit-action-#{@action.id}")
    assert_equal "Enter a reason", flash[:field_error]["message"]
    assert_equal "spamm", @action.reload.reason
  end

  test "edit to adult category without reason clears the reason" do
    sign_in_as(@me)
    patch fd_case_action_path(@kase, @action), params: { category_key: "adult" }

    assert_equal "Action updated", flash[:notice]
    @action.reload
    assert_equal "adult", @action.category_key
    assert_nil @action.reason
  end

  test "edit with unknown category is refused" do
    sign_in_as(@me)
    edit_action(category_key: "made_up")

    assert_equal "Select a category", flash[:alert]
    assert_equal "spam", @action.reload.category_key
  end

  test "edit keeps a retired category already on the action" do
    Fd::InfractionCategory.where(key: "spam").update_all(retired_at: Time.current)
    sign_in_as(@me)
    edit_action(category_key: "spam")

    assert_equal "spam", @action.reload.category_key
    assert_equal "spam in #lounge", @action.reason
  end

  test "edit with blank category clears it" do
    sign_in_as(@me)
    edit_action(category_key: "")

    assert_nil @action.reload.category_key
  end

  test "edit on a reversed action keeps it reversed" do
    @action.update!(reversed_at: 1.day.ago, reversed_by: "UFF1", reversal_reason: "appeal upheld")
    sign_in_as(@me)
    edit_action

    assert_equal "spam in #lounge", @action.reload.reason
    assert_not_nil @action.reversed_at
  end

  test "edit of an action on another case is not found" do
    other_case = make_case
    other_action = @action.dup.tap { |copy| copy.update!(case_id: other_case.id) }
    sign_in_as(@me)
    edit_action(other_action)

    assert_equal "Action not found", flash[:alert]
    assert_equal "spamm", other_action.reload.reason
  end

  test "edit of a thread lock action does not need a reason" do
    lock_action = Fd::Action.create!(
      case_id: @kase.id, type_key: Fd::Action::FROM_THREAD_LOCK.first, target_user_id: "USUB",
      decided_by: "UFF1", performed_by: "UFF1", source_app: "fire_engine", category_key: "spam"
    )
    sign_in_as(@me)
    edit_action(lock_action, reason: "", category_key: "advertising")

    assert_equal "advertising", lock_action.reload.category_key
  end

  test "case page shows the edit button and modal with current values" do
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "actions")

    assert_select "button[data-modal-open='edit-action-#{@action.id}']", text: "Edit"
    modal = "[data-modal-id-value='edit-action-#{@action.id}']"
    assert_select "#{modal} textarea[name='reason']", text: "spamm"
    assert_select "#{modal} select[name='category_key'] option[selected][value='spam']"
  end

  test "edit updates the solution" do
    sign_in_as(@me)
    edit_action(solution: "removed the post")

    assert_equal "removed the post", @action.reload.solution
  end
end
