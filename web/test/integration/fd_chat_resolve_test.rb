require "test_helper"

class FdChatResolveTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = grant_role!("UME", "community_manager")
    @kase = make_case
    sign_in_as(@me)
  end

  def create_reporter_conversation
    reporter = Fd::Member.first.user_id
    @report = Fd::CaseReport.create!(case_id: @kase.id, reporter_user_id: reporter,
      is_anonymous: false, body: "look at this", source_app: "relay", received_at: 2.days.ago)
    Fd::IntakeConversation.create!(report_id: @report.id, member_user_id: reporter,
      channel_id: "D0REP", thread_ts: "1700.5", opened_at: 2.days.ago)
  end

  test "resolve in reply mode resolves the case and queues the default outcome" do
    conversation = create_reporter_conversation
    post fd_case_replies_path(@kase), params: { body: "resolve", conversation_id: conversation.id },
      as: :turbo_stream

    assert_redirected_to fd_case_path(@kase, tab: "report")
    assert_equal "Case #{@kase.id} resolved", flash[:notice]
    @kase.reload
    assert_equal "no_action", @kase.resolution
    assert_equal "UME", @kase.resolution_echo_by
    assert_not_nil @report.reload.closed_at
    outcome = Fd::IntakeOutbox.sole
    assert_equal ["outcome", Fd::Resolution::DEFAULT_MESSAGE, "UME"],
      [outcome.kind, outcome.body, outcome.requested_by]
    assert Fd::AuditEntry.exists?(entity_type: "case", entity_id: @kase.id, verb: "resolved")
  end

  test "question mark resolve on the chat endpoint resolves the case" do
    create_reporter_conversation
    post fd_case_chats_path(@kase), params: { body: "?resolve" }, as: :turbo_stream

    assert @kase.reload.resolved?
    assert_equal 0, Fd::CaseChat.where(case_id: @kase.id).count
    assert_equal ["outcome"], Fd::IntakeOutbox.pluck(:kind)
  end

  test "bang resolve without a report resolves the case and queues nothing" do
    post fd_case_chats_path(@kase), params: { body: "!resolve" }, as: :turbo_stream

    assert @kase.reload.resolved?
    assert_equal 0, Fd::IntakeOutbox.count
    assert_equal 0, Fd::CaseChat.where(case_id: @kase.id).count
  end

  test "resolve with a live action resolves as action taken" do
    Fd::Action.create!(case_id: @kase.id, type_key: "warning", target_user_id: "USUB",
      decided_by: "UME", performed_by: "UME", source_app: "fire_engine", reason: "spam")
    post fd_case_chats_path(@kase), params: { body: "!resolve" }, as: :turbo_stream

    assert_equal "action_taken", @kase.reload.resolution
  end

  test "resolve without case resolve permission is refused" do
    sign_in_as(grant_role!("UFF2", "firefighter"))
    override_capability!("firefighter", "case.resolve", false)
    create_reporter_conversation
    post fd_case_replies_path(@kase), params: { body: "resolve" }, as: :turbo_stream

    assert_not @kase.reload.resolved?
    assert_equal 0, Fd::IntakeOutbox.count
    assert flash[:alert].present?
  end

  test "reply that only mentions resolve is sent as a normal reply" do
    create_reporter_conversation
    post fd_case_replies_path(@kase), params: { body: "resolve later" }, as: :turbo_stream

    assert_not @kase.reload.resolved?
    assert_equal [["reply", "resolve later"]], Fd::IntakeOutbox.pluck(:kind, :body)
  end
end
