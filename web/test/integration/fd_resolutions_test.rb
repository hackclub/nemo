require "test_helper"

class FdResolutionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @kase = make_case(opened_at: 3.days.ago)
  end

  def actions
    @kase.actions
  end

  def entries(verb)
    Fd::AuditEntry.where(verb: verb).where(
      "(entity_type = 'case' AND entity_id = :id) OR (entity_type = 'action' AND entity_id IN (:actions))",
      id: @kase.id, actions: actions.ids.presence || [-1]
    )
  end

  def act(**params)
    post fd_case_actions_path(@kase), params: {
      type_key: "warning", target_user_id: "USUB", reason: "would not let it go"
    }.merge(params)
  end

  def close(**params)
    post fd_case_resolution_path(@kase), params: { close_reason: "no_action" }.merge(params)
  end

  test "a signed out visitor cannot resolve, and nothing is written" do
    close
    assert_redirected_to login_path
    assert_nil @kase.reload.resolved_at
    assert_equal 0, actions.count
  end

  test "logging an action records it against the case" do
    sign_in_as(@me)
    act

    assert_nil @kase.reload.resolved_at, "logging an action does not close the case"

    action = actions.sole
    assert_equal "warning", action.type_key
    assert_equal "USUB", action.target_user_id
    assert_equal "UME", action.decided_by
    assert_equal "UME", action.performed_by
    assert_equal 1, entries("performed").count
  end

  test "an action and its audit row share one request id" do
    sign_in_as(@me)
    act
    ids = entries("performed").pluck(:request_id).uniq
    assert_equal 1, ids.size
    assert_not_nil ids.first
  end

  test "a shush without an end date is refused, and nothing is written" do
    sign_in_as(@me)
    act(type_key: "shush")

    assert_nil @kase.reload.resolved_at
    assert_equal 0, actions.count
    assert_match(/needs a date it runs until/, flash[:alert])
  end

  test "a shush with an end date records when it lifts" do
    sign_in_as(@me)
    act(type_key: "shush", expires_on: "2026-09-01")
    assert_equal Date.new(2026, 9, 1), actions.sole.expires_at.to_date
  end

  test "a channel ban without a channel is refused" do
    sign_in_as(@me)
    act(type_key: "channel_ban", expires_on: "2026-09-01")
    assert_equal 0, actions.count
    assert_match(/needs a channel/, flash[:alert])
  end

  test "a channel ban keeps the channel with the action" do
    sign_in_as(@me)
    act(type_key: "channel_ban", channel_id: "C0266FRGV", expires_on: "2026-09-01")
    assert_equal "C0266FRGV", actions.sole.details["channel_id"]
  end

  test "a warning takes neither an end date nor a channel" do
    sign_in_as(@me)
    act(type_key: "warning")
    assert_nil actions.sole.expires_at
    assert_empty actions.sole.details
  end

  test "fields the action does not use are ignored, not stored" do
    sign_in_as(@me)
    act(type_key: "warning", expires_on: "2026-09-01", channel_id: "C0266FRGV")

    action = actions.sole
    assert_nil action.expires_at, "a warning must not carry an expiry"
    assert_empty action.details, "a warning must not carry a channel"
  end

  test "a permanent ban does not expire even if a date is posted" do
    sign_in_as(@me)
    act(type_key: "perma_ban", expires_on: "2026-09-01")
    assert_nil actions.sole.expires_at
  end

  test "a locked thread may carry a channel but does not need one" do
    sign_in_as(@me)
    act(type_key: "locked_thread", channel_id: "C0266FRGV")
    assert_equal "C0266FRGV", actions.sole.details["channel_id"]
    assert_nil actions.sole.expires_at
  end

  test "an action type outside the eight is refused" do
    sign_in_as(@me)
    act(type_key: "banished")
    assert_equal 0, actions.count
    assert_match(/pick what was done/, flash[:alert])
  end

  test "an action with nobody to act on is refused" do
    sign_in_as(@me)
    act(target_user_id: "")
    assert_nil @kase.reload.resolved_at
  end

  test "closing records the reason and logs no action" do
    sign_in_as(@me)
    close(close_reason: "not_conduct")

    assert_equal "not_conduct", @kase.reload.resolution
    assert_equal 0, actions.count
    assert_equal 1, entries("resolved").count
  end

  test "closing for a reason outside the two is refused" do
    sign_in_as(@me)
    close(close_reason: "action_taken")
    assert_nil @kase.reload.resolved_at
    assert_match(/say why this case is closing/, flash[:alert])
  end

  test "an outcome nobody offered is refused" do
    sign_in_as(@me)
    post fd_case_resolution_path(@kase), params: { outcome: "vanish" }
    assert_nil @kase.reload.resolved_at
  end

  test "the reason is kept on the record and summarised in the trail" do
    sign_in_as(@me)
    close(member_note: "we spoke")

    assert_equal "we spoke", @kase.reload.member_note
    entry = entries("resolved").sole
    assert_equal "redacted, 8 chars", entry.after["member_note"]
    assert_no_match(/we spoke/, entry.after.to_json)
  end

  test "an empty reason is stored as nothing, not as blank text" do
    sign_in_as(@me)
    close(member_note: "")
    assert_nil @kase.reload.member_note
  end

  test "I can resolve a case somebody else is holding" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    close(member_note: "sorted between us")

    assert_not_nil @kase.reload.resolved_at, "assignment says who will, not who may"
    assert_nil flash[:alert]
  end

  test "an action on a case somebody else holds is allowed" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    act

    assert_equal 1, actions.count
  end

  test "resolving twice does not overwrite the first outcome" do
    sign_in_as(@me)
    close(member_note: "first")
    close(close_reason: "not_conduct", member_note: "second")

    @kase.reload
    assert_equal "no_action", @kase.resolution
    assert_equal "first", @kase.member_note
    assert_match(/already resolved/, flash[:alert])
  end

  test "resolving closes the reports that were still open" do
    report = Fd::CaseReport.create!(case_id: @kase.id, reporter_user_id: "UREP1",
      is_anonymous: false, body: "look at this", source_app: "shroud", received_at: 2.days.ago)
    sign_in_as(@me)
    close(member_note: "warned them", tell_reporter: "1")

    report.reload
    assert_not_nil report.closed_at
    assert_equal "UME", report.closed_by
    assert Fd::AuditEntry.exists?(entity_type: "report", verb: "closed",
      entity_id: @kase.id)
  end

  test "a report already closed is left as it was" do
    was = 3.days.ago.change(usec: 0)
    report = Fd::CaseReport.create!(case_id: @kase.id, is_anonymous: true,
      source_app: "shroud", received_at: 5.days.ago, closed_at: was, closed_by: "UFF9")
    sign_in_as(@me)
    close(member_note: "done")

    assert_equal "UFF9", report.reload.closed_by
    assert_equal was.to_i, report.closed_at.to_i
  end

  test "reopening puts the case back in the queue and says who did it" do
    sign_in_as(@me)
    close(member_note: "done")
    delete fd_case_resolution_path(@kase)

    @kase.reload
    assert_nil @kase.resolved_at
    assert_nil @kase.resolution
    assert_match(/open again/, flash[:notice])
    assert Fd::AuditEntry.exists?(entity_type: "case", entity_id: @kase.id, verb: "reopened")
  end

  test "reopening hands the case back to nobody" do
    @kase.assign!("UOTHER")
    @kase.assign!(@me.user_id)
    sign_in_as(@me)
    close(member_note: "done")

    delete fd_case_resolution_path(@kase)

    assert_empty @kase.reload.assignee_user_ids, "whoever had it is not on the hook again"
    entry = Fd::AuditEntry.where(entity_type: "case", entity_id: @kase.id, verb: "reopened").last
    assert_equal %w[UOTHER UME], entry.before["assignees"], "the record says who was let go"
    assert_empty entry.after["assignees"]
  end

  test "an open case cannot be reopened" do
    sign_in_as(@me)
    delete fd_case_resolution_path(@kase)

    assert_match(/already open/, flash[:alert])
  end

  test "the modal is offered while open and gone once resolved" do
    sign_in_as(@me)
    get fd_case_path(@kase)
    assert_select "input#resolve-case"
    assert_select "form[action=?]", fd_case_resolution_path(@kase)
    assert_select "form[action=?] select[name=close_reason]", fd_case_resolution_path(@kase)
    assert_select "form[action=?] .opt", fd_case_resolution_path(@kase), 0,
      "a case with no report has nobody to notify"

    close(member_note: "done")
    get fd_case_path(@kase)
    assert_select "input#resolve-case", count: 0
    assert_select ".closed .closed-what", text: /Closed/
    assert_select ".closed .closed-why", text: "done"
  end

  test "a case with an action logged closes as action taken, with no reason to pick" do
    sign_in_as(@me)
    act

    get fd_case_path(@kase)
    assert_select "select[name=close_reason]", count: 0
    assert_select ".said", text: /action taken, warning/

    close(close_reason: "not_conduct")
    assert_equal "action_taken", @kase.reload.resolution
  end

  test "a case with nothing done still has to say why it is closing" do
    sign_in_as(@me)
    post fd_case_resolution_path(@kase)

    assert_nil @kase.reload.resolved_at
    assert_match(/say why this case is closing/, flash[:alert])
  end

  test "a reversed action does not decide the ending" do
    sign_in_as(@me)
    act
    action = actions.sole
    action.update!(reversed_at: Time.current, reversed_by: "UME", reversal_reason: "wrong person")

    close
    assert_equal "no_action", @kase.reload.resolution
  end
end
