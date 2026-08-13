require "test_helper"

class FdClaimsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = make_case
  end

  def audit_rows(verb)
    Fd::AuditEntry.where(entity_type: "assignee", entity_id: @kase.id, verb: verb)
  end

  test "a signed out visitor cannot claim, and nothing is written" do
    post fd_case_claim_path(@kase)
    assert_redirected_to login_path
    assert_not @kase.reload.assigned?
    assert_equal 0, audit_rows("claimed").count
  end

  test "a staff row without the flag cannot claim" do
    denied = Staff.create!(user_id: "UNOPE", community_manager: false)
    sign_in_as(denied)
    post fd_case_claim_path(@kase)
    assert_not @kase.reload.assigned?
    assert_equal 0, audit_rows("claimed").count
  end

  test "claiming assigns the case and records who took it" do
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

  test "a second person claiming joins the case rather than being turned away" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    post fd_case_claim_path(@kase)

    assert_equal %w[UOTHER UME], @kase.reload.assignee_user_ids
    assert_equal 1, audit_rows("claimed").count
    assert_match(/is yours, alongside @UOTHER/, flash[:notice])
  end

  test "a resolved case cannot be claimed" do
    @kase.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    post fd_case_claim_path(@kase)

    assert_not @kase.reload.assigned?
    assert_match(/already resolved/, flash[:alert])
  end

  test "unclaiming releases my own case" do
    @kase.assign!("UME")
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    assert_not @kase.reload.assigned?
    assert_equal "UME", audit_rows("unclaimed").sole.actor_user_id
    assert_match(/back in the queue/, flash[:notice])
  end

  test "stepping off a shared case leaves it with the others" do
    @kase.assign!("UOTHER")
    @kase.assign!("UME")
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    assert_equal ["UOTHER"], @kase.reload.assignee_user_ids
    assert_match(/still with @UOTHER/, flash[:notice])
  end

  test "I cannot drop somebody else off a case" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    assert_equal ["UOTHER"], @kase.reload.assignee_user_ids
    assert_equal 0, audit_rows("unclaimed").count
    assert_match(/not to you/, flash[:alert])
  end

  test "claiming twice in a row is refused the second time" do
    sign_in_as(@me)
    post fd_case_claim_path(@kase)
    post fd_case_claim_path(@kase)

    assert_equal 1, audit_rows("claimed").count
    assert_equal 1, @kase.reload.assignees.count
    assert_match(/already yours/, flash[:alert])
  end

  test "the trail keeps who was taken off, since the row itself is gone" do
    @kase.assign!("UME")
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    entry = audit_rows("unclaimed").sole
    assert_equal "UME", entry.before["user_id"]
    assert_nil entry.after
  end

  test "every row from one claim shares a request id" do
    sign_in_as(@me)
    post fd_case_claim_path(@kase)
    assert_not_nil audit_rows("claimed").sole.request_id
  end
end
