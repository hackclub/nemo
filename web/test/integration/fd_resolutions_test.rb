require "test_helper"

class FdResolutionsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = Fd::Case.create!(subject_user_id: "USUB", opened_by: "UFF1", opened_at: 3.days.ago)
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

  def report(**params)
    post fd_case_resolution_path(@kase), params: {
      outcome: "report", type_key: "warning", target_user_id: "USUB",
    }.merge(params)
  end

  def close(**params)
    post fd_case_resolution_path(@kase), params: {
      outcome: "close", close_reason: "no_action",
    }.merge(params)
  end

  test "a signed out visitor cannot resolve, and nothing is written" do
    report
    assert_redirected_to login_path
    assert_nil @kase.reload.resolved_at
    assert_equal 0, actions.count
  end

  test "filing a report resolves the case and records the action in one go" do
    sign_in_as(@me)
    report(member_note: "warned them in DM")

    @kase.reload
    assert_equal "action_taken", @kase.resolution
    assert_not_nil @kase.resolved_at

    action = actions.sole
    assert_equal "warning", action.type_key
    assert_equal "USUB", action.target_user_id
    assert_equal "UME", action.decided_by
    assert_equal "UME", action.performed_by
    assert_equal 1, entries("performed").count
    assert_equal 1, entries("resolved").count
  end

  test "one report writes both rows under a single request id" do
    sign_in_as(@me)
    report
    ids = entries("performed").or(entries("resolved")).pluck(:request_id).uniq
    assert_equal 1, ids.size
    assert_not_nil ids.first
  end

  test "a shush without an end date is refused, and nothing is written" do
    sign_in_as(@me)
    report(type_key: "shush")

    assert_nil @kase.reload.resolved_at
    assert_equal 0, actions.count
    assert_match(/needs a date it runs until/, flash[:alert])
  end

  test "a shush with an end date records when it lifts" do
    sign_in_as(@me)
    report(type_key: "shush", expires_on: "2026-09-01")
    assert_equal Date.new(2026, 9, 1), actions.sole.expires_at.to_date
  end

  test "a channel ban without a channel is refused" do
    sign_in_as(@me)
    report(type_key: "channel_ban", expires_on: "2026-09-01")
    assert_equal 0, actions.count
    assert_match(/needs a channel/, flash[:alert])
  end

  test "a channel ban keeps the channel with the action" do
    sign_in_as(@me)
    report(type_key: "channel_ban", channel_id: "C0266FRGV", expires_on: "2026-09-01")
    assert_equal "C0266FRGV", actions.sole.details["channel_id"]
  end

  test "a warning takes neither an end date nor a channel" do
    sign_in_as(@me)
    report(type_key: "warning")
    assert_not_nil @kase.reload.resolved_at
    assert_nil actions.sole.expires_at
    assert_empty actions.sole.details
  end

  test "fields the action does not use are ignored, not stored" do
    sign_in_as(@me)
    report(type_key: "warning", expires_on: "2026-09-01", channel_id: "C0266FRGV")

    action = actions.sole
    assert_nil action.expires_at, "a warning must not carry an expiry"
    assert_empty action.details, "a warning must not carry a channel"
  end

  test "a permanent ban does not expire even if a date is posted" do
    sign_in_as(@me)
    report(type_key: "perma_ban", expires_on: "2026-09-01")
    assert_nil actions.sole.expires_at
  end

  test "a locked thread may carry a channel but does not need one" do
    sign_in_as(@me)
    report(type_key: "locked_thread", channel_id: "C0266FRGV")
    assert_equal "C0266FRGV", actions.sole.details["channel_id"]
    assert_nil actions.sole.expires_at
  end

  test "an action type outside the eight is refused" do
    sign_in_as(@me)
    report(type_key: "banished")
    assert_equal 0, actions.count
    assert_match(/pick what was done/, flash[:alert])
  end

  test "a report with nobody to act on is refused" do
    sign_in_as(@me)
    report(target_user_id: "")
    assert_nil @kase.reload.resolved_at
  end

  test "closing records the reason and logs no action" do
    sign_in_as(@me)
    close(close_reason: "not_conduct")

    assert_equal "not_conduct", @kase.reload.resolution
    assert_equal 0, actions.count
    assert_equal 1, entries("resolved").count
  end

  test "closing for a reason outside the two is refused" do
    sign_in_as(@me)
    close(close_reason: "action_taken")
    assert_nil @kase.reload.resolved_at
    assert_match(/say how this case ended/, flash[:alert])
  end

  test "an outcome nobody offered is refused" do
    sign_in_as(@me)
    post fd_case_resolution_path(@kase), params: { outcome: "vanish" }
    assert_nil @kase.reload.resolved_at
  end

  test "marking a duplicate links the two cases" do
    other = Fd::Case.create!(subject_user_id: "USUB", opened_by: "UFF1", opened_at: 4.days.ago)
    sign_in_as(@me)
    post fd_case_resolution_path(@kase), params: { outcome: "duplicate", duplicate_of: other.id }

    @kase.reload
    assert_equal "duplicate", @kase.resolution
    assert_equal other.id, @kase.duplicate_of
  end

  test "a duplicate keeps no reason, even if one is posted" do
    other = Fd::Case.create!(subject_user_id: "USUB", opened_by: "UFF1", opened_at: 4.days.ago)
    sign_in_as(@me)
    post fd_case_resolution_path(@kase),
      params: { outcome: "duplicate", duplicate_of: other.id, member_note: "typed then switched" }

    @kase.reload
    assert_equal "duplicate", @kase.resolution
    assert_nil @kase.member_note, "a duplicate is explained by the case it points at"
    assert_no_match(/typed then switched/, entries("resolved").sole.after.to_json)
  end

  test "the reason field is not offered for a duplicate" do
    sign_in_as(@me)
    get fd_case_path(@kase)
    assert_select "label.unless-duplicate textarea[name=member_note]"
  end

  test "a case cannot be a duplicate of itself" do
    sign_in_as(@me)
    post fd_case_resolution_path(@kase), params: { outcome: "duplicate", duplicate_of: @kase.id }
    assert_nil @kase.reload.resolved_at
    assert_match(/cannot duplicate itself/, flash[:alert])
  end

  test "a duplicate must point at a case that exists" do
    sign_in_as(@me)
    post fd_case_resolution_path(@kase), params: { outcome: "duplicate", duplicate_of: 999_999 }
    assert_nil @kase.reload.resolved_at
    assert_match(/does not exist/, flash[:alert])
  end

  test "the reason is kept on the record and summarised in the trail" do
    sign_in_as(@me)
    close(member_note: "we spoke")

    assert_equal "we spoke", @kase.reload.member_note
    entry = entries("resolved").sole
    assert_equal "redacted, 8 chars", entry.after["member_note"]
    assert_no_match(/we spoke/, entry.after.to_json)
  end

  test "an empty reason is stored as nothing, not as blank text" do
    sign_in_as(@me)
    close(member_note: "")
    assert_nil @kase.reload.member_note
  end

  test "I cannot resolve a case assigned to somebody else" do
    @kase.update!(claimed_by: "UOTHER", claimed_at: 1.hour.ago)
    sign_in_as(@me)
    report

    assert_nil @kase.reload.resolved_at
    assert_equal 0, actions.count
    assert_match(/assigned to @UOTHER, not to you/, flash[:alert])
  end

  test "resolving twice does not overwrite the first outcome or log twice" do
    sign_in_as(@me)
    report(member_note: "first")
    close(close_reason: "no_action", member_note: "second")

    @kase.reload
    assert_equal "action_taken", @kase.resolution
    assert_equal "first", @kase.member_note
    assert_equal 1, actions.count
    assert_match(/already resolved/, flash[:alert])
  end

  test "the modal is offered while open and gone once resolved" do
    sign_in_as(@me)
    get fd_case_path(@kase)
    assert_select "input#resolve-case"
    assert_select "form[action=?]", fd_case_resolution_path(@kase)
    assert_select ".opt", 3

    close(member_note: "done")
    get fd_case_path(@kase)
    assert_select "input#resolve-case", count: 0
    assert_match(/Reason recorded/, response.body)
    assert_match(/done/, response.body)
  end
end
