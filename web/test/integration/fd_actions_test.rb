require "test_helper"

class FdActionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
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

  test "create action posts one case chat row with the target and reason" do
    sign_in_as(@me)
    log

    echo = Fd::CaseChat.where(case_id: @kase.id).sole
    assert_equal "UME", echo.author_user_id
    assert_equal "fire_engine", echo.source_app
    assert_match(/<@USUB>/, echo.body)
    assert_match(/kept at it after being asked to stop/, echo.body)
  end


  test "action form has no resolution_note textarea and a Reason label" do
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "actions", do: "action")

    assert_select "textarea[name=?]", "resolution_note", false
    assert_select "label.field-label", text: /Reason/
  end

  test "create action signed out redirects to login and stores nothing" do
    log
    assert_redirected_to root_path
    assert_equal 0, actions.count
  end

  test "create action leaves the case open and stores the action" do
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
    assert_equal "Warning logged on case #{@kase.id}", flash[:notice]
  end

  test "create action writes a performed audit entry" do
    sign_in_as(@me)
    log

    entry = Fd::AuditEntry.where(entity_type: "action", entity_id: actions.ids, verb: "performed").sole
    assert_equal "UME", entry.actor_user_id
    assert_equal "warning", entry.after["type_key"]
    assert_not_nil entry.request_id
  end

  test "create action twice on one case stores two actions and leaves it open" do
    sign_in_as(@me)
    log(type_key: "warning")
    log(type_key: "shush", expires_on: "2026-09-01")

    assert_equal 2, actions.count
    assert_nil @kase.reload.resolved_at
  end

  test "create action rejects a missing end date or channel and an unknown type" do
    sign_in_as(@me)
    log(type_key: "temp_ban")
    assert_equal 0, actions.count
    assert_equal "Temporary ban needs an end date", flash[:alert]

    log(type_key: "channel_ban", expires_on: "2026-09-01")
    assert_equal 0, actions.count
    assert_match(/needs a channel/, flash[:alert])

    log(type_key: "banished")
    assert_equal 0, actions.count
    assert_match(/Select an action/, flash[:alert])
  end

  test "create warning ignores expires_on and channel_id" do
    sign_in_as(@me)
    log(type_key: "warning", expires_on: "2026-09-01", channel_id: "C0266FRGV")

    action = actions.sole
    assert_nil action.expires_at
    assert_empty action.details
  end

  test "create action on a case assigned to another member stores the action" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    log

    assert_equal 1, actions.count
  end

  test "create action on a case assigned to the actor stores the action" do
    @kase.assign!("UME")
    sign_in_as(@me)
    log
    assert_equal 1, actions.count
  end

  test "create action on a resolved case stores the action and sets the notice" do
    @kase.update!(resolved_at: 1.hour.ago, resolution: "action_taken")
    sign_in_as(@me)
    log

    assert_equal 1, actions.count
    assert_equal "Warning logged on case #{@kase.id}", flash[:notice]
  end

  test "create action with blank reason stores nothing and sets a reason field_error" do
    sign_in_as(@me)
    log(reason: "   ")

    assert_empty actions, "no action stored without a reason"
    assert_equal "reason", flash[:field_error]["field"]
  end

  test "create shush without expires_on stores nil expires_at" do
    sign_in_as(@me)
    log(type_key: "shush")

    assert_nil actions.sole.expires_at
  end

  test "create shush with expires_on and expires_time stores expires_at in utc" do
    sign_in_as(@me)
    log(type_key: "shush", expires_on: "2026-11-02", expires_time: "14:30")

    assert_equal Time.utc(2026, 11, 2, 14, 30), actions.sole.expires_at
  end

  test "create shush with expires_time and no expires_on stores nothing and alerts" do
    sign_in_as(@me)
    log(type_key: "shush", expires_time: "14:30")

    assert_empty actions
    assert_equal "Enter a date for the end time", flash[:alert]
  end

  test "create action reports the missing end date before the blank reason" do
    sign_in_as(@me)
    log(type_key: "temp_ban", reason: "")

    assert_equal "Temporary ban needs an end date", flash[:alert],
      "end date error is reported before the blank reason"
  end

  test "create action strips whitespace around reason" do
    sign_in_as(@me)
    log(reason: "  said it again in the same thread  ")

    assert_equal "said it again in the same thread", actions.sole.reason
  end

  test "create action stores category_key when given" do
    sign_in_as(@me)
    log(category_key: "harassment_general")

    assert_equal "harassment_general", actions.sole.category_key
  end

  test "create action without category_key uses the case category_key" do
    @kase.update!(category_key: "spam")
    sign_in_as(@me)
    log

    assert_equal "spam", actions.sole.category_key,
      "category_key comes from the case"
  end

  test "create action with unknown category_key stores nil category_key" do
    @kase.update!(category_key: nil)
    sign_in_as(@me)
    log(category_key: "nonsense")

    assert_nil actions.sole.category_key
  end

  test "create action with invalid expires_on redirects with a date alert" do
    sign_in_as(@me)
    log(type_key: "shush", expires_on: "2026-13-45")

    assert_response :redirect
    assert_equal 0, actions.count
    assert_match(/is not a date/, flash[:alert])
  end

  test "create action with array target_user_id redirects with a member id alert" do
    sign_in_as(@me)
    log(target_user_id: ["USUB"])

    assert_response :redirect
    assert_equal 0, actions.count
    assert_match(/is not a member id/, flash[:alert])
  end

  test "create channel_ban with array channel_id redirects with a channel id alert" do
    sign_in_as(@me)
    log(type_key: "channel_ban", expires_on: "2026-09-01", channel_id: ["C0266FRGV"])

    assert_response :redirect
    assert_equal 0, actions.count
    assert_match(/is not a channel id/, flash[:alert])
  end

  test "create action for a new target adds them as a case subject" do
    sign_in_as(@me)
    assert_not_includes @kase.subject_user_ids, "UNEW"

    log(target_user_id: "UNEW")

    assert_includes @kase.reload.subject_user_ids, "UNEW"
    assert_match(/@UNEW added to case/, flash[:notice])
    assert Fd::AuditEntry.where(entity_type: "participant", verb: "attached",
      entity_id: @kase.id).exists?, "attaching the subject is audited"
  end

  test "create action twice for one target adds the subject once" do
    sign_in_as(@me)
    log
    log

    assert_equal ["USUB"], @kase.reload.subject_user_ids
    assert_no_match(/added to case/, flash[:notice])
  end

  test "create action refused for a blank reason does not add the target as subject" do
    sign_in_as(@me)
    log(target_user_id: "UNEW", reason: "  ")

    assert_equal 0, actions.count
    assert_not_includes @kase.reload.subject_user_ids, "UNEW"
  end

  test "create adult category action without reason stores no reason and guards with the category label" do
    sign_in_as(@me)
    log(type_key: "shush", category_key: "adult", reason: "")

    action = actions.sole
    assert_nil action.reason
    assert_equal "adult", action.category_key
    assert_equal "Adult", Fd::MemberGuard.find(action.guard_id).reason
  end

  test "create action with another category and blank reason is refused" do
    sign_in_as(@me)
    log(category_key: "spam", reason: "")

    assert_equal 0, actions.count
    assert_equal "Enter a reason", flash[:field_error]["message"]
  end

  test "action form wires the reason field to the category select" do
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "actions", do: "action")

    assert_select "[data-controller~=reason-field][data-reason-field-categories-value=?]", '["adult"]'
    assert_select "select[name=category_key][data-reason-field-target=category]"
    assert_select "[data-reason-field-target=reason] textarea[name=reason]"
  end

  test "action form groups ban types under account deactivation" do
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "actions", do: "action")

    assert_select "select[name=type_key] optgroup[label=?] option", "Account deactivation", count: 3
    assert_select "optgroup[label=?] option[value=perma_ban][data-deactivates=true]", "Account deactivation"
    assert_select "optgroup[label=Actions] option[value=warning][data-deactivates=false]"
    assert_select "p.deactivation-note[data-action-standing-target=deactivation][hidden]"
    assert_select "input[type=submit][data-action-standing-target=submit][value=Log]"
  end

  test "create ban queues the deactivation in the notice" do
    sign_in_as(@me)
    log(type_key: "perma_ban")

    assert_equal "Permanent ban logged on case #{@kase.id} · deactivation queued", flash[:notice]
  end

  test "create deleted messages action stores a record with no guard" do
    sign_in_as(@me)
    log(type_key: "deleted_messages")

    action = actions.sole
    assert_equal "deleted_messages", action.type_key
    assert_nil action.guard_id
    assert_equal 0, Fd::MemberGuard.where(subject_id: "USUB").count
    assert_equal "Deleted messages logged on case #{@kase.id}", flash[:notice]
  end

  test "action form has the solution, resolvers and resolve case fields" do
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "actions", do: "action")

    assert_select "label.field-label", text: /How Was This Solved\? \(Text edition\)/
    assert_select "textarea[name=?]", "solution"
    assert_select ".field-label span", text: "Who Resolved This? (Thank you btw <3)"
    assert_select "[data-combobox-name-value=?]", "resolved_by[]"
    assert_select "input[type=checkbox][name=?]", "resolve_case"
  end

  test "create action stores the solution and the people who resolved it" do
    sign_in_as(@me)
    log(solution: "removed the post", resolved_by: ["UFF1", "UFF2"])

    action = actions.sole
    assert_equal "removed the post", action.solution
    assert_equal ["UFF1", "UFF2"], action.resolved_by
  end

  test "create action with no resolvers records the person logging" do
    sign_in_as(@me)
    log

    action = actions.sole
    assert_equal ["UME"], action.resolved_by
    assert_nil action.solution
  end

  test "create action with resolve case resolves the case as action taken" do
    sign_in_as(@me)
    log(resolve_case: "1")

    @kase.reload
    assert_not_nil @kase.resolved_at
    assert_equal "action_taken", @kase.resolution
    assert_equal "Warning logged on case #{@kase.id} · case resolved", flash[:notice]
    assert Fd::AuditEntry.where(entity_type: "case", entity_id: @kase.id, verb: "resolved").exists?
  end

  test "create action with resolve case is refused without case resolve" do
    firefighter = grant_role!("UFF", "firefighter")
    override_capability!("firefighter", "case.resolve", false)
    sign_in_as(firefighter)
    log(resolve_case: "1")

    assert_equal 0, actions.count
    assert_nil @kase.reload.resolved_at
    assert_equal "Not permitted to resolve cases", flash[:alert]
  end

  def open_report_with_conversation
    report = Fd::CaseReport.create!(case_id: @kase.id, is_anonymous: true,
      source_app: "relay", received_at: 2.days.ago)
    conversation = Fd::IntakeConversation.create!(channel_id: "DREPORTER", thread_ts: "1.1",
      report_id: report.id, handed_off_at: 2.days.ago)
    [report, conversation]
  end

  test "action form shows notify the reporter under resolve case on a reported case" do
    open_report_with_conversation
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "actions", do: "action")

    assert_select ".only-resolving input[type=checkbox][name=?][checked]", "notify_reporter"
    assert_select ".only-resolving.only-notifying textarea[name=?]", "member_message"
  end

  test "action form has no notify the reporter on a case without reports" do
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "actions", do: "action")

    assert_select ".only-resolving", false
  end

  test "create action with resolve case and notify closes the report and queues the message" do
    report, conversation = open_report_with_conversation
    sign_in_as(@me)
    log(resolve_case: "1", notify_reporter: "1", member_message: "all done")

    assert_equal "action_taken", @kase.reload.resolution
    assert_not_nil report.reload.closed_at
    outcome = Fd::IntakeOutbox.where(conversation_id: conversation.id, kind: "outcome").sole
    assert_equal "all done", outcome.body
  end

  test "create action with resolve case but no notify leaves the reporter untold" do
    report, conversation = open_report_with_conversation
    sign_in_as(@me)
    log(resolve_case: "1", member_message: "all done")

    assert_equal "action_taken", @kase.reload.resolution
    assert_nil report.reload.closed_at
    assert_equal 0, Fd::IntakeOutbox.where(conversation_id: conversation.id).count
  end

  test "create action with notify but no resolve case changes nothing for the reporter" do
    report, conversation = open_report_with_conversation
    sign_in_as(@me)
    log(notify_reporter: "1", member_message: "all done")

    assert_nil @kase.reload.resolved_at
    assert_nil report.reload.closed_at
    assert_equal 0, Fd::IntakeOutbox.where(conversation_id: conversation.id).count
  end

  test "actions tab shows the solution and the people who resolved it" do
    Fd::Action.create!(
      case_id: @kase.id, type_key: "warning", target_user_id: "USUB",
      decided_by: "UME", performed_by: "UME", performed_at: 1.hour.ago,
      source_app: "fire_engine", reason: "spam", solution: "removed the post",
      resolved_by: ["UME", "UFF2"]
    )
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "actions")

    assert_select ".lrow .sub", text: "removed the post"
    assert_select ".lrow .sub", text: /Resolved by/
  end
end
