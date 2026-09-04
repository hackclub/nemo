require "test_helper"

class FdActionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @kase = make_case
  end

  def log(**params)
    post fd_case_actions_path(@kase), params: {
      type_key: "warning", target_user_id: "USUB", reason: "kept at it after being asked to stop"
    }.merge(params)
  end

  def actions
    @kase.actions
  end

  test "a citation must point at a message on this case" do
    sign_in_as(@me)
    log(cites_message_id: "999999")

    assert_nil actions.sole.cites_message_id,
      "a message that is not held cannot be cited"
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

  test "I can act on a case assigned to somebody else" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    log

    assert_equal 1, actions.count
  end

  test "I can act on my own case" do
    @kase.assign!("UME")
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

    get fd_case_path(@kase, tab: "actions")
    assert_match(/Shush/, response.body)
    assert_select ".ledger-top b", text: "Shush"
  end

  test "the case page offers the log modal from the menu" do
    sign_in_as(@me)
    get fd_case_path(@kase)

    assert_select "input#log-action.modal-flip"
    assert_select ".menu-pop button[data-modal-open=log-action]"
    assert_select "form[action=?] select[name=type_key]", fd_case_actions_path(@kase)
  end

  test "the log modal carries its action fields without an id that could clash" do
    sign_in_as(@me)
    get fd_case_path(@kase)

    assert_select "select.action-type", 1
    assert_select "select#type_key", count: 0
  end

  test "an action must say why it was taken" do
    sign_in_as(@me)
    log(reason: "   ")

    assert_empty actions, "nothing may be logged against somebody without a reason"
    assert_equal "reason", flash[:wrong]["field"]
  end

  test "the reason is kept so it does not have to be typed twice" do
    sign_in_as(@me)
    log(type_key: "shush", reason: "")

    assert_equal "shush needs a date it runs until", flash[:alert],
      "the first objection still wins"
  end

  test "the reason is stored as written, trimmed" do
    sign_in_as(@me)
    log(reason: "  said it again in the same thread  ")

    assert_equal "said it again in the same thread", actions.sole.reason
  end

  test "a violation is optional, and a set one is kept on the action" do
    sign_in_as(@me)
    log(category_key: "harassment_general")

    assert_equal "harassment_general", actions.sole.category_key
  end

  test "an action with no violation chosen falls back to the case" do
    @kase.update!(category_key: "spam")
    sign_in_as(@me)
    log

    assert_equal "spam", actions.sole.category_key,
      "the case already says what this is about"
  end

  test "a violation that is not a real category is refused, not stored" do
    @kase.update!(category_key: nil)
    sign_in_as(@me)
    log(category_key: "nonsense")

    assert_nil actions.sole.category_key
  end

  test "an unparseable expiry is refused instead of raising" do
    sign_in_as(@me)
    log(type_key: "shush", expires_on: "2026-13-45")

    assert_response :redirect
    assert_equal 0, actions.count
    assert_match(/is not a date/, flash[:alert])
  end

  test "a target that is not a member id is refused instead of raising" do
    sign_in_as(@me)
    log(target_user_id: ["USUB"])

    assert_response :redirect
    assert_equal 0, actions.count
    assert_match(/is not a member id/, flash[:alert])
  end

  test "a channel sent as a list is refused instead of stored as nonsense" do
    sign_in_as(@me)
    log(type_key: "channel_ban", expires_on: "2026-09-01", channel_id: ["C0266FRGV"])

    assert_response :redirect
    assert_equal 0, actions.count
    assert_match(/is not a channel id/, flash[:alert])
  end
end
