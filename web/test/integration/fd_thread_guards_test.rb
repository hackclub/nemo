require "test_helper"

class FdThreadGuardsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
    @kase = make_case(subject: "USUB")
  end

  def guard!(**over)
    Fd::ThreadGuard.create!({
      kind: "lock", channel_id: "C0266FRGV", thread_ts: "1700000000.000100",
      opened_by: "UMOD", reason: "it was going nowhere", state: "running",
      expires_at: 3.days.from_now, case_id: @kase.id
    }.merge(over))
  end

  def actions_tab
    get fd_case_path(@kase, tab: "actions")
    response.body
  end

  test "actions tab lists lock guard with label reason and state" do
    guard!
    body = actions_tab

    assert_match(/Thread locked/, body)
    assert_match(/it was going nowhere/, body)
    assert_match(/running/, body)
  end

  test "actions tab labels destroy guard as Thread destroyed" do
    guard!(kind: "destroy", expires_at: nil, state: "done")
    assert_match(/Thread destroyed/, actions_tab)
  end

  test "actions tab shows note_text of a destroy guard" do
    guard!(kind: "destroy", expires_at: nil, state: "done",
      note_rich: { "type" => "rich_text" }, note_text: "we took this down, here is why",
      note_ts: "1700000000.000200", note_posted_at: Time.current)

    assert_match(/we took this down, here is why/, actions_tab)
  end

  test "actions tab renders no lcite for a destroy guard without note" do
    guard!(kind: "destroy", expires_at: nil, state: "done")

    assert_no_match(/lcite/, actions_tab)
  end

  test "actions tab marks a failed guard with failed text and state-crit class" do
    guard!(state: "failed", error: "the admin account could not be invited")
    body = actions_tab
    assert_match(/failed/, body)
    assert_match(/state-crit/, body)
  end

  test "actions tab omits the guard list for a guard on another case" do
    other = make_case
    guard!(case_id: other.id)
    actions_tab
    assert_select ".thread-guard-list", false
  end

  test "actions tab omits the guard list for a guard without case" do
    guard!(case_id: nil)
    actions_tab
    assert_select ".thread-guard-list", false
  end
  test "actions tab lock with future expires_at renders time left Unlock and extend end fields" do
    guard = guard!(expires_at: 2.hours.from_now + 5.minutes)
    body = actions_tab

    assert_match(/ends in 2h \d+m/, body)
    assert_select "form[action=?] button", fd_case_thread_lock_path(@kase, guard), text: "Unlock"
    assert_select "[data-modal-id-value=lock-extend-#{guard.id}] input[name=expires_on][value=?]",
      guard.expires_at.utc.to_date.iso8601
    assert_select "[data-modal-id-value=lock-extend-#{guard.id}] input[name=expires_time]"
  end

  test "actions tab lock without expires_at renders no end date" do
    guard!(expires_at: nil)

    assert_match(/no end date/, actions_tab)
  end

  test "extend sets expires_at from expires_on and expires_time in utc and writes extended audit entry" do
    guard = guard!
    first_end = guard.reload.expires_at
    ends = 5.days.from_now.utc.change(hour: 8, min: 0)

    patch fd_case_thread_lock_path(@kase, guard),
      params: { expires_on: ends.to_date.to_s, expires_time: "08:00" }

    assert_redirected_to fd_case_path(@kase)
    assert_equal ends, guard.reload.expires_at
    assert_equal "Lock extended · ends #{Fd::ShortDate.ending(ends)}", flash[:notice]
    entry = Fd::AuditEntry.where(entity_type: "thread_guard", entity_id: guard.id, verb: "extended").sole
    assert_equal first_end.iso8601, entry.before["expires_at"]
  end

  test "extend can move the end earlier" do
    guard = guard!(expires_at: 5.days.from_now)
    ends = 1.day.from_now.utc.change(hour: 8, min: 0)

    patch fd_case_thread_lock_path(@kase, guard),
      params: { expires_on: ends.to_date.to_s, expires_time: "08:00" }

    assert_equal ends, guard.reload.expires_at
  end

  test "extend without a date sets alert" do
    guard = guard!

    patch fd_case_thread_lock_path(@kase, guard)

    assert_equal "Enter the end date", flash[:alert]
  end

  test "extend with an end in the past keeps the lock end and sets alert" do
    guard = guard!
    first_end = guard.reload.expires_at

    patch fd_case_thread_lock_path(@kase, guard), params: { expires_on: 1.day.ago.to_date.to_s }

    assert_equal "End must be in the future", flash[:alert]
    assert_equal first_end, guard.reload.expires_at
  end

  test "unlock marks guard done and writes lifted audit entry" do
    guard = guard!

    delete fd_case_thread_lock_path(@kase, guard)

    assert_equal "Thread unlocked", flash[:notice]
    assert_equal "done", guard.reload.state
    assert guard.finished_at
    assert Fd::AuditEntry.exists?(entity_type: "thread_guard", entity_id: guard.id, verb: "lifted")
  end

  test "unlock on a done guard sets already ended alert" do
    guard = guard!(state: "done")

    delete fd_case_thread_lock_path(@kase, guard)

    assert_equal "Lock already ended", flash[:alert]
  end

  test "unlock without thread.guard leaves state running" do
    guard = guard!
    revoke_roles!("UME")
    grant_role!("UME", "gardener")

    delete fd_case_thread_lock_path(@kase, guard)

    assert_equal "running", guard.reload.state
  end

  test "channel overview lists live locks with and without a case" do
    on_case = guard!
    caseless = guard!(case_id: nil, thread_ts: "1700000000.000300", reason: "raid replies")
    guard!(thread_ts: "1700000000.000400", state: "done")
    guard!(channel_id: "C0OTHER", thread_ts: "1700000000.000500")

    get fd_channel_path("C0266FRGV")

    assert_select "h2", text: "Locked threads"
    assert_select "form[action=?] button", fd_channel_thread_lock_path("C0266FRGV", on_case), text: "Unlock"
    assert_select "form[action=?] button", fd_channel_thread_lock_path("C0266FRGV", caseless), text: "Unlock"
    assert_select "form button", text: "Unlock", count: 2
    assert_select "a[href=?]", fd_case_path(@kase.id), text: "Case ##{@kase.id}"
    assert_match(/Reason: raid replies/, response.body)
    assert_select "[data-modal-id-value=lock-extend-#{caseless.id}] input[name=expires_on]"
  end

  test "channel overview without live locks omits locked threads" do
    guard!(state: "done")

    get fd_channel_path("C0266FRGV")

    assert_select "h2", text: "Locked threads", count: 0
  end

  test "channel unlock lifts a caseless lock and returns to the channel" do
    guard = guard!(case_id: nil)

    delete fd_channel_thread_lock_path("C0266FRGV", guard)

    assert_redirected_to fd_channel_path("C0266FRGV")
    assert_equal "Thread unlocked", flash[:notice]
    assert_equal "done", guard.reload.state
    assert Fd::AuditEntry.exists?(entity_type: "thread_guard", entity_id: guard.id, verb: "lifted", actor_user_id: "UME")
  end

  test "channel unlock for a lock in another channel leaves it running" do
    guard = guard!(case_id: nil)

    delete fd_channel_thread_lock_path("C0OTHER", guard)

    assert_equal "Lock already ended", flash[:alert]
    assert_equal "running", guard.reload.state
  end

  test "channel extend moves a caseless lock end and returns to the channel" do
    guard = guard!(case_id: nil)
    ends = 5.days.from_now.utc.change(hour: 8, min: 0)

    patch fd_channel_thread_lock_path("C0266FRGV", guard),
      params: { expires_on: ends.to_date.to_s, expires_time: "08:00" }

    assert_redirected_to fd_channel_path("C0266FRGV")
    assert_equal ends, guard.reload.expires_at
  end
end
