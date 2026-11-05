require "test_helper"

class FdScheduledDeactivationsTest < ActionDispatch::IntegrationTest
  MEMBER = "USUB".freeze

  setup do
    @me = grant_role!("UME", "community_manager")
    @kase = make_case
    sign_in_as(@me)
  end

  def starts = 3.days.from_now.utc.change(hour: 14, min: 0)

  def schedule(**over)
    post fd_member_guards_path(MEMBER), params: {
      kind: Fd::MemberGuard::DEACTIVATION, reason: "raid next week",
      starts_on: starts.to_date.iso8601, starts_time: "14:00"
    }.merge(over)
  end

  def scheduled!(**over)
    Fd::MemberGuard.create!({
      kind: "deactivation", subject_id: MEMBER, opened_by: "UMOD", reason: "raid next week",
      state: "scheduled", starts_at: starts, expires_at: starts + 7.days
    }.merge(over))
  end

  def guards = Fd::MemberGuard.for_subject(MEMBER)

  def audit_entries(verb) = Fd::AuditEntry.where(entity_type: "member_guard", verb: verb)

  test "create deactivation with a future start opens a scheduled guard and audits scheduled" do
    schedule(expires_on: (starts + 7.days).to_date.iso8601, expires_time: "14:00")

    guard = guards.sole
    assert_equal "scheduled", guard.state
    assert_equal starts, guard.starts_at
    assert_equal starts + 7.days, guard.expires_at
    assert_equal "pending", guard.enforcement_status
    assert_equal 1, audit_entries("scheduled").count
    assert_equal 0, audit_entries("opened").count
    assert_match(/Deactivation scheduled for .* · starts /, flash[:notice])
  end

  test "create deactivation without a start opens a live guard" do
    schedule(starts_on: "", starts_time: "")

    assert_equal "live", guards.sole.state
    assert_nil guards.sole.starts_at
  end

  test "create deactivation with a past start creates no guard" do
    schedule(starts_on: 1.day.ago.to_date.iso8601)

    assert_empty guards
    assert_equal "Start must be in the future", flash[:alert]
    assert_redirected_to fd_member_path(MEMBER, do: "deactivate")
  end

  test "create deactivation ending before its start creates no guard" do
    schedule(expires_on: starts.to_date.iso8601, expires_time: "13:00")

    assert_empty guards
    assert_equal "End must be after the start", flash[:alert]
  end

  test "create second scheduled deactivation creates no row" do
    scheduled!
    schedule

    assert_equal 1, guards.count
    assert_match(/already has a scheduled deactivation/, flash[:alert])
  end

  test "start on a shush is ignored" do
    post fd_member_guards_path(MEMBER), params: {
      kind: "shush", reason: "loud", starts_on: starts.to_date.iso8601
    }

    assert_equal "live", guards.sole.state
    assert_nil guards.sole.starts_at
  end

  test "scheduled deactivation with purge_messages queues a purge on the scheduled guard" do
    schedule(purge_messages: "1")

    assert_equal guards.sole.id, Fd::ChannelPurge.where(member_id: MEMBER).sole.guard_id
  end

  test "member page lists the scheduled deactivation with edit and cancel" do
    guard = scheduled!
    get fd_member_path(MEMBER)

    assert_select ".standing-row[data-enforcement-status=scheduled] .enforcement-state", "Scheduled"
    assert_select ".standing-row .sub", text: /starts #{Regexp.escape(Fd::ShortDate.starting(starts))}/
    assert_select "button[data-modal-open=?]", "guard-reschedule-#{guard.id}"
    assert_select "button[data-modal-open=?]", "guard-cancel-#{guard.id}"
    assert_select "[data-modal-id-value=guard-reschedule-#{guard.id}] input[name=starts_on][value=?]", starts.to_date.iso8601
  end

  test "member standing frame lists the scheduled deactivation" do
    scheduled!
    get fd_member_standing_path(MEMBER)

    assert_select ".standing-row[data-enforcement-status=scheduled]"
  end

  test "member page deactivate modal has start fields" do
    get fd_member_path(MEMBER)

    assert_select "[data-modal-id-value=member-deactivate] input[name=starts_on][type=date]"
    assert_select "[data-modal-id-value=member-deactivate] input[name=starts_time][type=time]"
  end

  test "destroy on a scheduled deactivation cancels it without lifting" do
    guard = scheduled!
    delete fd_member_guard_path(MEMBER, guard), params: { cancel_reason: "appeal accepted" }

    guard.reload
    assert_equal "cancelled", guard.state
    assert_equal "UME", guard.cancelled_by
    assert_equal "appeal accepted", guard.cancel_reason
    assert_not_nil guard.cancelled_at
    assert_nil guard.lifted_at
    assert_equal 1, audit_entries("cancelled").count
    assert_equal 0, audit_entries("lifted").count
    assert_match(/Scheduled deactivation cancelled/, flash[:notice])
  end

  test "update on a scheduled deactivation moves its start and end" do
    guard = scheduled!
    later = starts + 2.days
    patch fd_member_guard_path(MEMBER, guard), params: {
      starts_on: later.to_date.iso8601, starts_time: "09:30",
      expires_on: (later + 3.days).to_date.iso8601, expires_time: "09:30"
    }

    guard.reload
    assert_equal later.change(hour: 9, min: 30), guard.starts_at
    assert_equal (later + 3.days).change(hour: 9, min: 30), guard.expires_at
    assert_equal "scheduled", guard.state
    assert_equal 1, audit_entries("edited").count
  end

  test "update on a scheduled deactivation without a start keeps it" do
    guard = scheduled!
    patch fd_member_guard_path(MEMBER, guard), params: { starts_on: "", expires_on: "" }

    assert_equal starts, guard.reload.starts_at
    assert_equal "Enter a start date", flash[:alert]
  end

  test "destroy on a scheduled deactivation without member deactivate leaves it scheduled" do
    guard = scheduled!
    sign_in_as(grant_role!("UFF2", "firefighter"))
    override_capability!("firefighter", "member.deactivate", false)

    delete fd_member_guard_path(MEMBER, guard)

    assert_equal "scheduled", guard.reload.state
  end

  test "case ban with a start opens a scheduled guard on the case" do
    post fd_case_actions_path(@kase), params: {
      type_key: "temp_ban", target_user_id: MEMBER, reason: "raid next week",
      starts_on: starts.to_date.iso8601, starts_time: "14:00",
      expires_on: (starts + 7.days).to_date.iso8601
    }

    guard = guards.sole
    assert_equal ["scheduled", @kase.id, starts], [guard.state, guard.case_id, guard.starts_at]
    assert_equal guard.id, @kase.actions.sole.guard_id
    assert_equal "Temporary ban logged on case #{@kase.id} · deactivation starts #{Fd::ShortDate.starting(starts)}",
      flash[:notice]
  end

  test "case ban with a past start logs nothing" do
    post fd_case_actions_path(@kase), params: {
      type_key: "perma_ban", target_user_id: MEMBER, reason: "raid", starts_on: 1.day.ago.to_date.iso8601
    }

    assert_empty @kase.actions
    assert_equal "Start must be in the future", flash[:alert]
  end

  test "case ban with a start for a member already scheduled logs nothing" do
    scheduled!
    post fd_case_actions_path(@kase), params: {
      type_key: "perma_ban", target_user_id: MEMBER, reason: "raid", starts_on: starts.to_date.iso8601
    }

    assert_empty @kase.actions
    assert_equal "#{MEMBER} already has a scheduled deactivation", flash[:alert]
  end

  test "case warning ignores a start" do
    post fd_case_actions_path(@kase), params: {
      type_key: "warning", target_user_id: MEMBER, reason: "rude", starts_on: starts.to_date.iso8601
    }

    assert_equal 1, @kase.actions.count
    assert_empty guards
  end

  test "action form has hidden start fields for bans" do
    get fd_case_path(@kase, tab: "actions", do: "action")

    assert_select "[data-action-standing-target=start][hidden] input[name=starts_on][type=date]"
  end

  test "actions tab shows when a scheduled ban starts" do
    guard = scheduled!(case_id: @kase.id)
    make_ban(guard)
    get fd_case_path(@kase, tab: "actions")

    assert_select ".lrow .chip", "Starts #{Fd::ShortDate.starting(starts)}"
  end

  test "reversing a scheduled ban cancels the deactivation" do
    guard = scheduled!(case_id: @kase.id)
    action = make_ban(guard)

    post fd_case_reversals_path(@kase), params: { action_id: action.id, reversal_reason: "appeal upheld" }

    guard.reload
    assert_equal "cancelled", guard.state
    assert_equal "Action reversed: appeal upheld", guard.cancel_reason
    assert_equal "Action reversed · scheduled deactivation cancelled", flash[:notice]
  end

  test "reversing a scheduled ban needs member deactivate" do
    guard = scheduled!(case_id: @kase.id)
    action = make_ban(guard)
    sign_in_as(grant_role!("UFF2", "firefighter"))
    override_capability!("firefighter", "member.deactivate", false)

    post fd_case_reversals_path(@kase), params: { action_id: action.id, reversal_reason: "appeal upheld" }

    assert_nil action.reload.reversed_at
    assert_equal "scheduled", guard.reload.state
  end

  test "enforcement history shows a cancelled deactivation" do
    scheduled!(state: "cancelled", cancelled_at: Time.utc(2026, 11, 4, 10), cancelled_by: "UME")
    get fd_member_path(MEMBER, tab: "enforcement")

    assert_select ".data-table td", text: /\ACancelled /
  end

  def make_ban(guard)
    Fd::Action.create!(
      case_id: @kase.id, type_key: "temp_ban", target_user_id: MEMBER, decided_by: "UME",
      performed_by: "UME", performed_at: Time.current, source_app: "fire_engine",
      expires_at: guard.expires_at, guard_id: guard.id
    )
  end
end
