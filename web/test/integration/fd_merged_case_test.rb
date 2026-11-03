require "test_helper"

class FdMergedCaseTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
    @root = make_case(subject: "USUB", opened_at: 10.days.ago)
    @duplicate = make_case(subject: "USUB", opened_at: 4.days.ago)
    @duplicate.update!(resolved_at: 2.days.ago, resolution: "duplicate", duplicate_of: @root.id)
  end

  def act_on(kase, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: "USUB",
                         decided_by: "UFF1", performed_by: "UFF1",
                         performed_at: 1.day.ago }.merge(attrs))
  end

  test "show for case without merged cases returns success" do
    unmerged = make_case(subject: "UOTHER", opened_at: 3.days.ago)
    act_on(unmerged)

    get fd_case_path(unmerged)
    assert_response :success
  end

  def report_on(kase, reporter_id, at:)
    report = Fd::CaseReport.create!(case_id: kase.id, reporter_user_id: reporter_id,
      is_anonymous: false, body: "#{reporter_id} said something", source_app: "relay", received_at: at)
    Fd::IntakeConversation.create!(report_id: report.id, member_user_id: reporter_id,
      channel_id: "D0#{reporter_id}", thread_ts: "1700.#{report.id}", opened_at: at)
    report
  end

  test "reply with merged case conversation_id writes outbox row for it" do
    user_ids = Fd::Member.order(:user_id).limit(2).pluck(:user_id)
    report_on(@root, user_ids.first, at: 3.days.ago)
    duplicate_report = report_on(@duplicate, user_ids.last, at: 6.days.ago)
    conversation = Fd::IntakeConversation.find_by(report_id: duplicate_report.id)

    post fd_case_replies_path(@root), params: { body: "we are on it",
      conversation_id: conversation.id }, as: :turbo_stream

    assert_equal conversation.id, Fd::IntakeOutbox.sole.conversation_id
  end

  def resolved_count
    Fd::CaseQuery.view_counts(nil)["resolved"]
  end

  test "view_counts resolved excludes merged duplicate cases" do
    get fd_cases_path(view: "resolved")

    resolved_before = resolved_count
    @duplicate.update!(duplicate_of: nil)

    assert_equal resolved_count - 1, resolved_before, "merged case counted as resolved"
  end

  test "QueueStats excludes merged case from resolved count and median but not total" do
    start = Time.current.beginning_of_month
    @duplicate.update!(opened_at: start + 1.minute, resolved_at: start + 2.minutes)
    stats_with_merge = Fd::QueueStats.load
    @duplicate.update!(duplicate_of: nil)
    stats_without_merge = Fd::QueueStats.load

    assert_equal stats_without_merge.opened_month_resolved - 1, stats_with_merge.opened_month_resolved
    assert_not_equal stats_without_merge.median_now, stats_with_merge.median_now
    assert_equal stats_without_merge.total, stats_with_merge.total, "total differs with merged case"
  end

  def slack_report_on(kase, at:, forwarded_ts:)
    Fd::CaseReport.create!(case_id: kase.id, is_anonymous: true, body: "report on #{kase.id}",
      source_app: "relay", received_at: at, card_channel_id: "C0FIRE", forwarded_ts: forwarded_ts)
  end

  test "show selects the case report thread over a newer merged report thread" do
    own = slack_report_on(@root, at: 3.days.ago, forwarded_ts: "1700000000.000100")
    merged = slack_report_on(@duplicate, at: 1.day.ago, forwarded_ts: "1700000000.000200")

    get fd_case_path(@root)

    assert_equal own.id, @controller.view_assigns["thread"].id
    assert_select "a.thread-tab[aria-current='true'][href*='thread=#{own.id}']"

    get fd_case_path(@root, thread: merged.id)

    assert_equal merged.id, @controller.view_assigns["thread"].id
  end

  test "chat head links the selected report thread to Slack" do
    slack_report_on(@root, at: 3.days.ago, forwarded_ts: "1700000000.000100")
    merged = slack_report_on(@duplicate, at: 1.day.ago, forwarded_ts: "1700000000.000200")

    get fd_case_path(@root, thread: merged.id)

    assert_select ".chat-head a[href='https://hackclub.slack.com/archives/C0FIRE/p1700000000000200']",
      text: "Open in Slack"
  end

  test "chat line shows the files attached to it" do
    report = slack_report_on(@root, at: 3.days.ago, forwarded_ts: "1700000000.000100")
    line = Fd::CaseChat.create!(case_id: @root.id, author_user_id: "UFF1", body: "",
      posted_at: 2.days.ago, channel_id: "C0FIRE", ts: "1700000100.000100",
      thread_ts: report.forwarded_ts, source_app: "nemo")
    file = Fd::IntakeFile.create!(slack_file_id: "FCHAT1", name: "shot.png", mimetype: "image/png",
      fetch_state: "pending")
    ApplicationRecord.connection.exec_query(
      "INSERT INTO fd.case_chat_files (chat_id, file_id, seq) VALUES ($1, $2, 0)",
      "chat file", [line.id, file.id]
    )

    get fd_case_path(@root)

    assert_select "#message-chat-#{line.id} .msg-files", text: /shot\.png/
  end

  test "view_counts resolved counts a case resolved without duplicate_of" do
    resolved_before = resolved_count
    @duplicate.update!(resolution: "no_action", duplicate_of: nil)

    assert_equal resolved_before + 1, resolved_count
  end
end
