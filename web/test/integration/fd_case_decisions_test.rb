require "test_helper"

class FdCaseDecisionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
    @case = make_case(opened_at: 3.days.ago, category_key: "spam")
  end

  def settled(title:, **attrs)
    decision = Fd::Decision.create!({ title: title, statement: "banned on sight",
      proposed_by: "UFF1" }.merge(attrs))
    decision.settle!(by: "ULEAD")
    decision
  end

  test "a case records which decision it followed" do
    decision = settled(title: "Spam accounts", category_key: "spam")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }

    assert_equal decision.id, @case.reload.followed_decision_id
    assert Fd::AuditEntry.exists?(entity_type: "case", entity_id: @case.id, verb: "followed")
  end

  test "a case can sit behind a proposal, which is how a proposal earns settling" do
    proposal = Fd::Decision.create!(title: "Appeals", statement: "read by somebody else",
      proposed_by: "UFF1")
    post fd_case_decision_path(@case), params: { decision_id: proposal.id }

    assert_equal proposal.id, @case.reload.followed_decision_id
    assert_equal [@case.id], proposal.cases_followed.ids
  end

  test "a retired decision can be linked too, cases were decided under it" do
    rule = settled(title: "Spam accounts")
    dead = settled(title: "Warnings by DM")
    dead.supersede!(rule, by: "ULEAD")

    post fd_case_decision_path(@case), params: { decision_id: dead.id }
    assert_equal dead.id, @case.reload.followed_decision_id
  end

  test "a decision that does not exist is refused" do
    post fd_case_decision_path(@case), params: { decision_id: 999_999 }

    assert_nil @case.reload.followed_decision_id
  end

  test "the pointer can be taken off again" do
    decision = settled(title: "Spam accounts")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }
    delete fd_case_decision_path(@case)

    assert_nil @case.reload.followed_decision_id
    assert Fd::AuditEntry.exists?(entity_type: "case", entity_id: @case.id, verb: "unfollowed")
  end

  test "a case assigned to somebody else is not mine to tag" do
    decision = settled(title: "Spam accounts")
    @case.assign!("UOTHER")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }

    assert_nil @case.reload.followed_decision_id
  end

  test "a signed out visitor cannot tag a case" do
    decision = settled(title: "Spam accounts")
    delete logout_path
    post fd_case_decision_path(@case), params: { decision_id: decision.id }

    assert_nil @case.reload.followed_decision_id
  end

  test "the case page renders with a decision on it" do
    decision = settled(title: "Spam accounts")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }

    get fd_case_path(@case)
    assert_response :success

    get fd_decision_path(decision)
    assert_response :success
  end

  test "the timeline records linking and unlinking" do
    decision = settled(title: "Spam accounts")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }
    delete fd_case_decision_path(@case)

    timeline = Fd::CaseTimeline.for(@case.reload, reports: [], actions: [], notes: [],
      links: Fd::AuditEntry.decision_links_for(case_id: @case.id).to_a,
      decisions: { decision.id => decision.title })

    assert_equal ["Decision linked", "Decision unlinked"],
      timeline.map(&:title).select { |title| title.start_with?("Decision") }
    assert timeline.any? { |entry| entry.detail.to_s.include?("Spam accounts") }
  end

  test "reopening a case drops what it followed, along with the outcome" do
    decision = settled(title: "Spam accounts")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }
    post fd_case_resolution_path(@case), params: { outcome: "close", close_reason: "no_action" }
    delete fd_case_resolution_path(@case)

    @case.reload
    assert_nil @case.resolved_at
    assert_nil @case.followed_decision_id
  end

  test "a decision that cases followed cannot be deleted out from under them" do
    decision = settled(title: "Spam accounts")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }

    assert_raises(ActiveRecord::StatementInvalid) { decision.destroy! }
  end
end
