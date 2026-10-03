require "test_helper"

class FdActionThreadLockTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    @kase = make_case(subject: "USUB")
  end

  def lock!(**over)
    Fd::ThreadGuard.create!({
      kind: "lock", channel_id: "C0266FRGV", thread_ts: "1700000000.000100",
      opened_by: "UMOD", reason: "it was going nowhere", state: "running",
      expires_at: 3.days.from_now, case_id: nil
    }.merge(over))
  end

  def log(**params)
    post fd_case_actions_path(@kase), params: { type_key: "locked_thread" }.merge(params)
  end

  def actions = @kase.actions.reload

  test "logging a lock records it against the case with no member" do
    guard = lock!
    log(thread_guard_id: guard.id)

    action = actions.sole
    assert_equal "locked_thread", action.type_key
    assert_nil action.target_user_id
    assert_equal guard.id, action.thread_guard_id
    assert_equal "C0266FRGV", action.details["channel_id"]
    assert_equal "1700000000.000100", action.details["thread_ts"]
  end

  test "the lock carries its own reason and expiry onto the action" do
    guard = lock!
    log(thread_guard_id: guard.id, reason: "typed into the box and ignored")

    action = actions.sole
    assert_equal "it was going nowhere", action.reason
    assert_equal guard.expires_at.to_i, action.expires_at.to_i
  end

  test "an orphaned lock is adopted by the case it is logged on" do
    guard = lock!(case_id: nil)
    log(thread_guard_id: guard.id)

    assert_equal @kase.id, guard.reload.case_id
    assert_equal 1, Fd::AuditEntry.where(entity_type: "thread_guard", verb: "attached").count
    assert_match(/the thread is now on this case/, flash[:notice])
  end

  test "a lock already on another case is logged without being moved" do
    other = make_case
    guard = lock!(case_id: other.id)
    log(thread_guard_id: guard.id)

    assert_equal other.id, guard.reload.case_id
    assert_equal 1, actions.count
    assert_no_match(/now on this case/, flash[:notice].to_s)
  end

  test "logging a lock names nobody as a subject" do
    guard = lock!
    was = @kase.subject_user_ids.sort
    log(thread_guard_id: guard.id, target_user_id: "UNEW")

    assert_nil actions.sole.target_user_id
    assert_equal was, @kase.reload.subject_user_ids.sort
  end

  test "a lock must be picked" do
    log(thread_guard_id: "")

    assert_equal 0, actions.count
    assert_match(/pick which thread lock/, flash[:alert])
  end

  test "a lock that has already lifted cannot be logged" do
    guard = lock!(state: "done")
    log(thread_guard_id: guard.id)

    assert_equal 0, actions.count
    assert_match(/pick which thread lock/, flash[:alert])
  end

  test "the same lock is not logged on the case twice" do
    guard = lock!
    log(thread_guard_id: guard.id)
    log(thread_guard_id: guard.id)

    assert_equal 1, actions.count
    assert_match(/already on this case/, flash[:alert])
  end

  test "a lock already on the case is offered but cannot be picked" do
    guard = lock!(case_id: @kase.id)
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/name="thread_guard_id" value="#{guard.id}"/, body)
    assert_select %(input[name="thread_guard_id"][value="#{guard.id}"][disabled])
    assert_match(/already on this case/, body)
  end

  test "a lock already on the case is refused even if the form is forced" do
    guard = lock!(case_id: @kase.id)
    log(thread_guard_id: guard.id)

    assert_equal 0, actions.count
    assert_match(/already on this case/, flash[:alert])
  end

  test "a lock held elsewhere but logged here is greyed out too" do
    other = make_case
    guard = lock!(case_id: other.id)
    log(thread_guard_id: guard.id)
    get fd_case_path(@kase, do: "action")

    assert_select %(input[name="thread_guard_id"][value="#{guard.id}"][disabled])
    assert_match(/already logged on this case/, response.body)
  end

  test "a lock on another case stays pickable here" do
    other = make_case
    guard = lock!(case_id: other.id)
    get fd_case_path(@kase, do: "action")

    assert_select %(input[name="thread_guard_id"][value="#{guard.id}"][disabled]), false
  end

  test "a lock logged here but held by another case is refused a second time" do
    other = make_case
    guard = lock!(case_id: other.id)
    log(thread_guard_id: guard.id)
    log(thread_guard_id: guard.id)

    assert_equal 1, actions.count
    assert_match(/already logged on this case/, flash[:alert])
  end

  test "the form offers every live lock, this case first" do
    mine = lock!(case_id: @kase.id, thread_ts: "1700000000.000200")
    loose = lock!(case_id: nil, thread_ts: "1700000000.000300")
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_operator body.index(%(value="#{mine.id}")), :<, body.index(%(value="#{loose.id}"))
    assert_match(/on this case/, body)
    assert_match(/on no case/, body)
  end

  test "a lifted lock is not offered" do
    gone = lock!(state: "done", thread_ts: "1700000000.000400")
    get fd_case_path(@kase, do: "action")

    assert_no_match(/name="thread_guard_id" value="#{gone.id}"/, response.body)
  end

  test "the picker and the member fields start hidden behind the kind" do
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/data-action-standing-target="locks" hidden/, body)
    assert_match(/data-action-standing-target="aimed"/, body)
    assert_match(/data-action-standing-target="why"/, body)
  end

  test "a logged lock reads as being on a thread, not a member" do
    guard = lock!
    log(thread_guard_id: guard.id)
    get fd_case_path(@kase, tab: "actions")

    assert_match(/On a thread/, response.body)
    assert_no_match(/On n\/a/, response.body)
  end

  test "a logged lock does not land on anybody's record" do
    guard = lock!
    log(thread_guard_id: guard.id)

    assert_empty Fd::Action.for_target(nil).where.not(case_id: nil).where(target_user_id: "USUB")
    assert_equal 0, Fd::Action.for_target("USUB").count
  end

  test "logging a lock needs the right to act" do
    drop_roles!("UME")
    guard = lock!
    log(thread_guard_id: guard.id)

    assert_equal 0, actions.count
  end
end
