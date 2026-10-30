require "test_helper"

class FdResolutionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
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

  test "resolution create signed out redirects to login and changes nothing" do
    close
    assert_redirected_to login_path
    assert_nil @kase.reload.resolved_at
    assert_equal 0, actions.count
  end

  test "action create stores one action and one performed entry and keeps case open" do
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

  test "action create audit entries share one request_id" do
    sign_in_as(@me)
    act
    ids = entries("performed").pluck(:request_id).uniq
    assert_equal 1, ids.size
    assert_not_nil ids.first
  end

  test "action create temp_ban without expires_on stores nothing and flashes alert" do
    sign_in_as(@me)
    act(type_key: "temp_ban")

    assert_nil @kase.reload.resolved_at
    assert_equal 0, actions.count
    assert_equal "Temporary ban needs an end date", flash[:alert]
  end

  test "action create shush with expires_on stores expires_at" do
    sign_in_as(@me)
    act(type_key: "shush", expires_on: "2026-09-01")
    assert_equal Date.new(2026, 9, 1), actions.sole.expires_at.to_date
  end

  test "action create channel_ban without channel_id is refused" do
    sign_in_as(@me)
    act(type_key: "channel_ban", expires_on: "2026-09-01")
    assert_equal 0, actions.count
    assert_match(/needs a channel/, flash[:alert])
  end

  test "action create channel_ban stores channel_id in details" do
    sign_in_as(@me)
    act(type_key: "channel_ban", channel_id: "C0266FRGV", expires_on: "2026-09-01")
    assert_equal "C0266FRGV", actions.sole.details["channel_id"]
  end

  test "action create warning stores no expires_at and empty details" do
    sign_in_as(@me)
    act(type_key: "warning")
    assert_nil actions.sole.expires_at
    assert_empty actions.sole.details
  end

  test "action create warning ignores expires_on and channel_id params" do
    sign_in_as(@me)
    act(type_key: "warning", expires_on: "2026-09-01", channel_id: "C0266FRGV")

    action = actions.sole
    assert_nil action.expires_at, "warning must not store an expiry"
    assert_empty action.details, "warning must not store a channel"
  end

  test "action create perma_ban ignores expires_on" do
    sign_in_as(@me)
    act(type_key: "perma_ban", expires_on: "2026-09-01")
    assert_nil actions.sole.expires_at
  end

  test "action create locked_thread uses channel_id and thread_ts from the thread guard" do
    sign_in_as(@me)
    lock = Fd::ThreadGuard.create!(kind: "lock", channel_id: "C0266FRGV",
      thread_ts: "1700000000.000100", opened_by: "UMOD", reason: "it was going nowhere",
      state: "running", expires_at: 3.days.from_now)
    act(type_key: "locked_thread", channel_id: "CELSE", thread_guard_id: lock.id)

    assert_equal "C0266FRGV", actions.sole.details["channel_id"]
    assert_equal "1700000000.000100", actions.sole.details["thread_ts"]
    assert_equal lock.id, actions.sole.thread_guard_id
  end

  test "action create with unknown type_key is refused" do
    sign_in_as(@me)
    act(type_key: "banished")
    assert_equal 0, actions.count
    assert_match(/Select an action/, flash[:alert])
  end

  test "action create with blank target_user_id does not close the case" do
    sign_in_as(@me)
    act(target_user_id: "")
    assert_nil @kase.reload.resolved_at
  end

  test "resolution create stores resolution and one resolved entry and no action" do
    sign_in_as(@me)
    close(close_reason: "not_conduct")

    assert_equal "not_conduct", @kase.reload.resolution
    assert_equal 0, actions.count
    assert_equal 1, entries("resolved").count
  end

  test "resolution create with close_reason action_taken is refused" do
    sign_in_as(@me)
    close(close_reason: "action_taken")
    assert_nil @kase.reload.resolved_at
    assert_match(/Select a resolution/, flash[:alert])
  end

  test "resolution create with unknown outcome keeps the case open" do
    sign_in_as(@me)
    post fd_case_resolution_path(@kase), params: { outcome: "vanish" }
    assert_nil @kase.reload.resolved_at
  end

  test "resolution create stores member_note and redacts it in the audit entry" do
    sign_in_as(@me)
    close(member_note: "we spoke")

    assert_equal "we spoke", @kase.reload.member_note
    entry = entries("resolved").sole
    assert_equal "redacted, 8 chars", entry.after["member_note"]
    assert_no_match(/we spoke/, entry.after.to_json)
  end

  test "resolution create with blank member_note stores nil" do
    sign_in_as(@me)
    close(member_note: "")
    assert_nil @kase.reload.member_note
  end

  test "resolution create succeeds for a non-assignee" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    close(member_note: "sorted between us")

    assert_not_nil @kase.reload.resolved_at, "resolve must succeed for a non-assignee"
    assert_nil flash[:alert]
  end

  test "action create succeeds for a non-assignee" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    act

    assert_equal 1, actions.count
  end

  test "resolution create twice keeps the first resolution and member_note" do
    sign_in_as(@me)
    close(member_note: "first")
    close(close_reason: "not_conduct", member_note: "second")

    @kase.reload
    assert_equal "no_action", @kase.resolution
    assert_equal "first", @kase.member_note
    assert_match(/already resolved/, flash[:alert])
  end

  test "resolution create closes open reports and audits report closed" do
    report = Fd::CaseReport.create!(case_id: @kase.id, reporter_user_id: "UREP1",
      is_anonymous: false, body: "look at this", source_app: "relay", received_at: 2.days.ago)
    sign_in_as(@me)
    close(member_note: "warned them", notify_reporter: "1")

    report.reload
    assert_not_nil report.closed_at
    assert_equal "UME", report.closed_by
    assert Fd::AuditEntry.exists?(entity_type: "report", verb: "closed",
      entity_id: @kase.id)
  end

  test "resolution create keeps closed_at and closed_by of a closed report" do
    original_closed_at = 3.days.ago.change(usec: 0)
    report = Fd::CaseReport.create!(case_id: @kase.id, is_anonymous: true,
      source_app: "relay", received_at: 5.days.ago, closed_at: original_closed_at, closed_by: "UFF9")
    sign_in_as(@me)
    close(member_note: "done")

    assert_equal "UFF9", report.reload.closed_by
    assert_equal original_closed_at.to_i, report.closed_at.to_i
  end

  test "resolution destroy clears resolution and audits case reopened" do
    sign_in_as(@me)
    close(member_note: "done")
    delete fd_case_resolution_path(@kase)

    @kase.reload
    assert_nil @kase.resolved_at
    assert_nil @kase.resolution
    assert_match(/reopened/, flash[:notice])
    assert Fd::AuditEntry.exists?(entity_type: "case", entity_id: @kase.id, verb: "reopened")
  end

  test "reopen retains assignees" do
    @kase.assign!("UOTHER")
    @kase.assign!(@me.user_id)
    sign_in_as(@me)
    close(member_note: "done")

    delete fd_case_resolution_path(@kase)

    assert_equal %w[UOTHER UME], @kase.reload.assignee_user_ids
  end

  test "resolution destroy reopens reports closed by the resolution" do
    report = Fd::CaseReport.create!(case_id: @kase.id, reporter_user_id: "UREP1",
      is_anonymous: false, body: "look at this", source_app: "relay", received_at: 2.days.ago)
    sign_in_as(@me)
    close(member_note: "done", notify_reporter: "1")

    delete fd_case_resolution_path(@kase)

    report.reload
    assert_nil report.closed_at
    assert_nil report.closed_by
    entry = Fd::AuditEntry.where(entity_type: "report", entity_id: @kase.id, verb: "reopened").sole
    assert_equal "UME", entry.before["closed_by"]
  end

  test "resolution create after reopen creates a second outcome outbox row" do
    report = Fd::CaseReport.create!(case_id: @kase.id, is_anonymous: true,
      source_app: "relay", received_at: 2.days.ago)
    conversation = Fd::IntakeConversation.create!(channel_id: "DREPORTER", thread_ts: "1.1",
      report_id: report.id, handed_off_at: 2.days.ago)
    sign_in_as(@me)

    close(member_note: "done", notify_reporter: "1")
    delete fd_case_resolution_path(@kase)
    close(member_note: "done again", notify_reporter: "1")

    outcomes = Fd::IntakeOutbox.where(conversation_id: conversation.id, kind: "outcome")
    assert_equal 2, outcomes.count
  end

  test "resolution destroy on an open case flashes already open" do
    sign_in_as(@me)
    delete fd_case_resolution_path(@kase)

    assert_match(/already open/, flash[:alert])
  end

  test "resolution create after an action overrides close_reason with action_taken" do
    sign_in_as(@me)
    act

    get fd_case_path(@kase)

    close(close_reason: "not_conduct")
    assert_equal "action_taken", @kase.reload.resolution
  end

  test "resolution create without close_reason is refused" do
    sign_in_as(@me)
    post fd_case_resolution_path(@kase)

    assert_nil @kase.reload.resolved_at
    assert_match(/Select a resolution/, flash[:alert])
  end

  test "resolution create with a reversed action stores no_action" do
    sign_in_as(@me)
    act
    action = actions.sole
    action.update!(reversed_at: Time.current, reversed_by: "UME", reversal_reason: "wrong person")

    close
    assert_equal "no_action", @kase.reload.resolution
  end
end
