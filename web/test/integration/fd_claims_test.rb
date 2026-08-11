require "test_helper"

class FdClaimsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = Fd::Case.create!(subject_user_id: "USUB", opened_by: "UFF1", opened_at: 2.days.ago)
  end

  def audit_rows(verb)
    Fd::AuditEntry.where(entity_type: "case", entity_id: @kase.id, verb: verb)
  end

  test "a signed out visitor cannot claim, and nothing is written" do
    post fd_case_claim_path(@kase)
    assert_redirected_to login_path
    assert_nil @kase.reload.claimed_by
    assert_equal 0, audit_rows("claimed").count
  end

  test "a staff row without the flag cannot claim" do
    denied = Staff.create!(user_id: "UNOPE", community_manager: false)
    sign_in_as(denied)
    post fd_case_claim_path(@kase)
    assert_nil @kase.reload.claimed_by
    assert_equal 0, audit_rows("claimed").count
  end

  test "claiming assigns the case and records who took it" do
    sign_in_as(@me)
    post fd_case_claim_path(@kase)
    assert_redirected_to fd_case_path(@kase)

    @kase.reload
    assert_equal "UME", @kase.claimed_by
    assert_not_nil @kase.claimed_at

    entry = audit_rows("claimed").sole
    assert_equal "UME", entry.actor_user_id
    assert_equal "human", entry.actor_kind
    assert_nil entry.before["claimed_by"]
    assert_equal "UME", entry.after["claimed_by"]
  end

  test "a second claim does not steal the case and writes no second row" do
    @kase.update!(claimed_by: "UOTHER", claimed_at: 1.hour.ago)
    sign_in_as(@me)
    post fd_case_claim_path(@kase)

    assert_equal "UOTHER", @kase.reload.claimed_by
    assert_equal 0, audit_rows("claimed").count
    assert_match(/claimed by @UOTHER/, flash[:alert])
  end

  test "a resolved case cannot be claimed" do
    @kase.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    post fd_case_claim_path(@kase)

    assert_nil @kase.reload.claimed_by
    assert_match(/already resolved/, flash[:alert])
  end

  test "unclaiming releases my own case" do
    @kase.update!(claimed_by: "UME", claimed_at: 1.hour.ago)
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    @kase.reload
    assert_nil @kase.claimed_by
    assert_nil @kase.claimed_at
    assert_equal "UME", audit_rows("unclaimed").sole.actor_user_id
  end

  test "I cannot drop somebody else's case" do
    @kase.update!(claimed_by: "UOTHER", claimed_at: 1.hour.ago)
    sign_in_as(@me)
    delete fd_case_claim_path(@kase)

    assert_equal "UOTHER", @kase.reload.claimed_by
    assert_equal 0, audit_rows("unclaimed").count
    assert_match(/not to you/, flash[:alert])
  end

  test "claiming twice in a row is refused the second time" do
    sign_in_as(@me)
    post fd_case_claim_path(@kase)
    post fd_case_claim_path(@kase)

    assert_equal 1, audit_rows("claimed").count
    assert_match(/already yours/, flash[:alert])
  end

  test "every row from one claim shares a request id" do
    sign_in_as(@me)
    post fd_case_claim_path(@kase)
    assert_not_nil audit_rows("claimed").sole.request_id
  end
end
