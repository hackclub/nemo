require "test_helper"

class FdActionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = Fd::Case.create!(subject_user_id: "USUB", opened_by: "UFF1", opened_at: 2.days.ago)
  end

  def log(**params)
    post fd_case_actions_path(@kase), params: {
      type_key: "warning", target_user_id: "USUB",
    }.merge(params)
  end

  def actions
    @kase.actions
  end

  test "a signed out visitor cannot log an action" do
    log
    assert_redirected_to login_path
    assert_equal 0, actions.count
  end

  test "logging an action leaves the case open" do
    sign_in_as(@me)
    log

    @kase.reload
    assert_nil @kase.resolved_at, "logging an action must not close the case"
    assert_nil @kase.resolution

    action = actions.sole
    assert_equal "warning", action.type_key
    assert_equal "USUB", action.target_user_id
    assert_equal "UME", action.decided_by
    assert_equal "UME", action.performed_by
    assert_match(/stays open/, flash[:notice])
  end

  test "the action is recorded in the trail as performed" do
    sign_in_as(@me)
    log

    entry = Fd::AuditEntry.where(entity_type: "action", entity_id: actions.ids, verb: "performed").sole
    assert_equal "UME", entry.actor_user_id
    assert_equal "warning", entry.after["type_key"]
    assert_not_nil entry.request_id
  end

  test "several actions can pile up on one open case" do
    sign_in_as(@me)
    log(type_key: "warning")
    log(type_key: "shush", expires_on: "2026-09-01")

    assert_equal 2, actions.count
    assert_nil @kase.reload.resolved_at
  end

  test "the same validation as filing a report applies here" do
    sign_in_as(@me)
    log(type_key: "shush")
    assert_equal 0, actions.count
    assert_match(/needs a date it runs until/, flash[:alert])

    log(type_key: "channel_ban", expires_on: "2026-09-01")
    assert_equal 0, actions.count
    assert_match(/needs a channel/, flash[:alert])

    log(type_key: "banished")
    assert_equal 0, actions.count
    assert_match(/pick what was done/, flash[:alert])
  end

  test "fields the action does not use are ignored here too" do
    sign_in_as(@me)
    log(type_key: "warning", expires_on: "2026-09-01", channel_id: "C0266FRGV")

    action = actions.sole
    assert_nil action.expires_at
    assert_empty action.details
  end

  test "I cannot act on a case assigned to somebody else" do
    @kase.update!(claimed_by: "UOTHER", claimed_at: 1.hour.ago)
    sign_in_as(@me)
    log

    assert_equal 0, actions.count
    assert_match(/assigned to @UOTHER, not to you/, flash[:alert])
  end

  test "I can act on my own case" do
    @kase.update!(claimed_by: "UME", claimed_at: 1.hour.ago)
    sign_in_as(@me)
    log
    assert_equal 1, actions.count
  end

  test "an action can still be logged after the case resolved" do
    @kase.update!(resolved_at: 1.hour.ago, resolution: "action_taken")
    sign_in_as(@me)
    log

    assert_equal 1, actions.count
    assert_no_match(/stays open/, flash[:notice])
  end

  test "the logged action shows in what was done" do
    sign_in_as(@me)
    log(type_key: "shush", expires_on: "2026-09-01")

    get fd_case_path(@kase)
    assert_match(/Shush/, response.body)
    assert_select ".data-table"
  end

  test "the case page offers the log modal from the menu" do
    sign_in_as(@me)
    get fd_case_path(@kase)

    assert_select "input#log-action.modal-flip"
    assert_select ".menu-pop label[for=log-action]"
    assert_select "form[action=?] select[name=type_key]", fd_case_actions_path(@kase)
  end

  test "both modals carry their own action fields without clashing ids" do
    sign_in_as(@me)
    get fd_case_path(@kase)

    assert_select "select.action-type", 2
    assert_select "select#type_key", count: 0
  end
end
