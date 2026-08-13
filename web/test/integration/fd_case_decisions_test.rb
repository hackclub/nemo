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
    assert_match(/following Spam accounts/, flash[:notice])
    assert Fd::AuditEntry.exists?(entity_type: "case", entity_id: @case.id, verb: "followed")
  end

  test "a case can sit behind a proposal, which is how a proposal earns settling" do
    proposal = Fd::Decision.create!(title: "Appeals", statement: "read by somebody else",
      proposed_by: "UFF1")
    post fd_case_decision_path(@case), params: { decision_id: proposal.id }

    assert_equal proposal.id, @case.reload.followed_decision_id
    assert_match(/behind the Appeals proposal/, flash[:notice])

    get fd_case_path(@case)
    assert_select "a.chip.chip-warn", text: "behind Appeals"

    get fd_decision_path(proposal)
    assert_select ".band-label", text: /Cases behind it · 1/
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
    assert_match(/pick a decision/, flash[:alert])
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
    assert_match(/not to you/, flash[:alert])
  end

  test "a signed out visitor cannot tag a case" do
    decision = settled(title: "Spam accounts")
    delete logout_path
    post fd_case_decision_path(@case), params: { decision_id: decision.id }

    assert_nil @case.reload.followed_decision_id
  end

  test "the control lives in the menu, and only when the log has something in it" do
    get fd_case_path(@case)
    assert_select "label[for=follow-decision]", count: 0

    Fd::Decision.create!(title: "Appeals", statement: "read by somebody else",
      proposed_by: "UFF1")
    get fd_case_path(@case)
    assert_select ".menu-pop label[for=follow-decision]", text: "Link a decision"
  end

  test "the picker groups by state, in force first" do
    settled(title: "Spam accounts")
    Fd::Decision.create!(title: "Appeals", statement: "read by somebody else",
      proposed_by: "UFF1")

    get fd_case_path(@case)

    assert_equal ["In force", "Proposed"],
      css_select("#follow-decision ~ .modal-wrap optgroup").map { |group| group["label"] }
  end

  test "the case says what it followed, and links to it" do
    decision = settled(title: "Spam accounts")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }
    get fd_case_path(@case)

    assert_select "a.chip[href=?]", fd_decision_path(decision), text: "followed Spam accounts"
  end

  test "the decision names the cases that followed it, and counts them on the log" do
    decision = settled(title: "Spam accounts")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }

    get fd_decision_path(decision)
    assert_select ".band-label", text: /Cases that followed it · 1/
    assert_select "a[href=?]", fd_case_path(@case)

    get fd_decisions_path
    assert_select "td.col-num", text: "1 case"
  end

  test "a decision nothing has followed says so on both pages" do
    decision = settled(title: "Night shift")

    get fd_decision_path(decision)
    assert_select ".card-note", text: "No case linked yet."

    get fd_decisions_path
    assert_select "td.col-num", text: "n/a"
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

  test "the timeline says when a decision was linked, and when it was taken off" do
    decision = settled(title: "Spam accounts")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }
    get fd_case_path(@case)

    assert_select ".tl-title", text: "Decision linked"
    assert_select ".tl-detail", text: /Spam accounts/

    delete fd_case_decision_path(@case)
    get fd_case_path(@case)

    assert_select ".tl-title", text: "Decision unlinked"
    assert_select ".tl-detail", text: /Spam accounts/
  end

  test "a decision that cases followed cannot be deleted out from under them" do
    decision = settled(title: "Spam accounts")
    post fd_case_decision_path(@case), params: { decision_id: decision.id }

    assert_raises(ActiveRecord::StatementInvalid) { decision.destroy! }
  end
end
