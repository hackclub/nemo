require "test_helper"

class FdClaimsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    @kase = make_case
  end

  def audit_rows(verb)
    Fd::AuditEntry.where(entity_type: "assignee", entity_id: @kase.id, verb: verb)
  end

  test "claim signed out redirects to login and assigns nothing" do
    post fd_case_claim_path(@kase)
    assert_redirected_to login_path
    assert_not @kase.reload.assigned?
    assert_equal 0, audit_rows("claimed").count
  end

  test "claim by an account with no role assigns nothing and writes no audit row" do
    denied = Account.create!(user_id: "UNOPE")
    sign_in_as(denied)
    post fd_case_claim_path(@kase)
    assert_not @kase.reload.assigned?
    assert_equal 0, audit_rows("claimed").count
  end

  test "claim assigns the case and writes a claimed audit row" do
    sign_in_as(@me)
    post fd_case_claim_path(@kase)
    assert_redirected_to fd_case_path(@kase)

    assert_equal ["UME"], @kase.reload.assignee_user_ids
    assert_not_nil @kase.assignees.sole.assigned_at

    entry = audit_rows("claimed").sole
    assert_equal "UME", entry.actor_user_id
    assert_equal "human", entry.actor_kind
    assert_equal "UME", entry.after["user_id"]
  end

  test "claim on an assigned case adds the claimer as a second assignee" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    post fd_case_claim_path(@kase)

    assert_equal %w[UOTHER UME], @kase.reload.assignee_user_ids
    assert_equal 1, audit_rows("claimed").count
    assert_match(/claimed · also assigned to @UOTHER/, flash[:notice])
  end

  test "claim on a resolved case assigns nothing and alerts" do
    @kase.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    post fd_case_claim_path(@kase)

    assert_not @kase.reload.assigned?
    assert_match(/already resolved/, flash[:alert])
  end

  test "unclaim removes own assignment and writes an unclaimed audit row" do
    @kase.assign!("UME")
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    assert_not @kase.reload.assigned?
    assert_equal "UME", audit_rows("unclaimed").sole.actor_user_id
    assert_match(/released/, flash[:notice])
  end

  test "unclaim on a shared case keeps the other assignee" do
    @kase.assign!("UOTHER")
    @kase.assign!("UME")
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    assert_equal ["UOTHER"], @kase.reload.assignee_user_ids
    assert_match(/still assigned to @UOTHER/, flash[:notice])
  end

  test "unclaim by a non-assignee keeps assignees and writes no audit row" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    assert_equal ["UOTHER"], @kase.reload.assignee_user_ids
    assert_equal 0, audit_rows("unclaimed").count
    assert_match(/is assigned to @UOTHER/, flash[:alert])
  end

  test "second claim by the same member is rejected with an alert" do
    sign_in_as(@me)
    post fd_case_claim_path(@kase)
    post fd_case_claim_path(@kase)

    assert_equal 1, audit_rows("claimed").count
    assert_equal 1, @kase.reload.assignees.count
    assert_match(/already claimed/, flash[:alert])
  end

  test "unclaimed audit row stores the assignee in before and nil in after" do
    @kase.assign!("UME")
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    entry = audit_rows("unclaimed").sole
    assert_equal "UME", entry.before["user_id"]
    assert_nil entry.after
  end

  test "claimed audit row has a request id" do
    sign_in_as(@me)
    post fd_case_claim_path(@kase)
    assert_not_nil audit_rows("claimed").sole.request_id
  end
end
