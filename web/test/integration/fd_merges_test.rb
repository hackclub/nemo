require "test_helper"

class FdMergesTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @main = make_case
    @dup_one = make_case
    @dup_two = make_case
  end

  def merge(ids, target, **params)
    post fd_merge_cases_path,
      params: { case_ids: Array(ids).map(&:to_s), duplicate_of: target.to_s }.merge(params)
  end

  test "a signed out visitor cannot merge anything" do
    merge([@dup_one.id], @main.id)
    assert_redirected_to login_path
    assert_nil @dup_one.reload.resolved_at
  end

  test "several cases close as duplicates of one main case" do
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    [@dup_one, @dup_two].each do |kase|
      kase.reload
      assert_equal "duplicate", kase.resolution
      assert_equal @main.id, kase.duplicate_of
      assert_not_nil kase.resolved_at
    end

    assert_nil @main.reload.resolved_at, "the main case must stay open"
    assert_match(/2 cases closed as duplicates of case #{@main.id}, which stays open/, flash[:notice])
  end

  test "each duplicate keeps its own threads and people" do
    Fd::CaseThread.create!(case_id: @dup_one.id, channel_id: "C1", thread_ts: "1.1",
      is_primary: true, added_by: "UFF1")
    Fd::CaseParticipant.create!(case_id: @dup_one.id, user_id: "UINV", role: "involved",
      detail: "they piled on")

    sign_in_as(@me)
    merge([@dup_one.id], @main.id)

    assert_equal 1, @dup_one.reload.threads.count
    assert_equal %w[involved subject], @dup_one.participants.map(&:role).sort
    assert_equal 0, @main.reload.threads.count
  end

  test "the main case is ignored even if it is ticked too" do
    sign_in_as(@me)
    merge([@main.id, @dup_one.id], @main.id)

    assert_nil @main.reload.resolved_at
    assert_equal "duplicate", @dup_one.reload.resolution
    assert_match(/1 case closed as duplicate/, flash[:notice])
  end

  test "a chain of duplicates collapses to the original" do
    @main.update!(resolved_at: 1.hour.ago, resolution: "duplicate", duplicate_of: @dup_two.id)
    sign_in_as(@me)
    merge([@dup_one.id], @main.id)

    assert_equal @dup_two.id, @dup_one.reload.duplicate_of,
      "pointing at a duplicate must resolve to the case it duplicates"
  end

  test "already resolved cases are left alone and counted" do
    @dup_two.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    assert_equal "no_action", @dup_two.reload.resolution
    assert_match(/1 case closed as duplicate of case #{@main.id}, which stays open, 1 left alone/, flash[:notice])
  end

  test "every ticked case being resolved already says only that" do
    @dup_one.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    @dup_two.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    assert_equal "nothing to mark: those cases are resolved already", flash[:alert]
  end

  test "a case assigned to somebody else still merges" do
    @dup_one.assign!("UOTHER")
    sign_in_as(@me)
    merge([@dup_one.id], @main.id)

    assert_not_nil @dup_one.reload.resolved_at
    assert_equal @main.id, @dup_one.duplicate_of
  end

  test "with no case named, the oldest of the ticked ones stays open" do
    @main.update!(opened_at: 9.days.ago)
    sign_in_as(@me)
    post fd_merge_cases_path, params: { case_ids: [@main.id, @dup_one.id, @dup_two.id].map(&:to_s) }

    assert_nil @main.reload.resolved_at, "the oldest must stay open"
    assert_equal @main.id, @dup_one.reload.duplicate_of
    assert_equal @main.id, @dup_two.reload.duplicate_of
  end

  test "ticking a single case explains that duplicates need two" do
    sign_in_as(@me)
    post fd_merge_cases_path, params: { case_ids: [@dup_one.id.to_s] }
    assert_nil @dup_one.reload.resolved_at
    assert_match(/tick at least two cases/, flash[:alert])
  end

  test "merging with nothing ticked is refused" do
    sign_in_as(@me)
    merge([], @main.id)
    assert_match(/tick the cases/, flash[:alert])
  end

  test "a named case that does not exist is refused" do
    sign_in_as(@me)
    merge([@dup_one.id], 999_999)
    assert_nil @dup_one.reload.resolved_at
    assert_match(/nothing to keep/, flash[:alert])
  end

  test "every duplicate writes its own trail entry under one request" do
    sign_in_as(@me)
    merge([@dup_one.id, @dup_two.id], @main.id)

    rows = Fd::AuditEntry.where(entity_type: "case", entity_id: [@dup_one.id, @dup_two.id],
      verb: "resolved")
    assert_equal 2, rows.count
    assert_equal 1, rows.pluck(:request_id).uniq.size
    assert_equal [@main.id, @main.id], rows.map { |r| r.after["duplicate_of"] }
  end

  test "the merge body groups the candidates and names the outcome" do
    sign_in_as(@me)
    get fd_case_merge_path(@dup_one)

    assert_response :success
  end

  def in_order
    @main.update!(opened_at: 3.days.ago)
    @dup_one.update!(opened_at: 2.days.ago)
    @dup_two.update!(opened_at: 1.day.ago)
  end

  test "the confirmation names every ticked case and merges nothing yet" do
    in_order
    sign_in_as(@me)
    get fd_confirm_merge_cases_path(case_ids: [@dup_two.id, @main.id, @dup_one.id])

    assert_response :success
    assert_equal 0, Fd::Case.where(id: [@main.id, @dup_one.id, @dup_two.id])
      .where.not(resolved_at: nil).count
  end

  test "confirming with one case ticked is refused" do
    sign_in_as(@me)
    get fd_confirm_merge_cases_path(case_ids: [@main.id])

    assert_redirected_to fd_cases_path
    assert_match(/tick at least two/, flash[:alert])
  end
end
