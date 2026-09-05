require "test_helper"

class FdMergedCaseTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    @root = make_case(subject: "USUB", opened_at: 10.days.ago)
    @folded = make_case(subject: "USUB", opened_at: 4.days.ago)
    @folded.update!(resolved_at: 2.days.ago, resolution: "duplicate", duplicate_of: @root.id)
  end

  def act_on(kase, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: "USUB",
                         decided_by: "UFF1", performed_by: "UFF1",
                         performed_at: 1.day.ago }.merge(attrs))
  end

  test "a case with nothing merged into it is unchanged" do
    alone = make_case(subject: "UOTHER", opened_at: 3.days.ago)
    act_on(alone)

    get fd_case_path(alone)
    assert_response :success
  end

  test "a thread from the folded case can be detached from the holding case" do
    thread = Fd::CaseThread.create!(case_id: @folded.id, channel_id: "C0LOUNGE",
      thread_ts: "1700.2", kind: "evidence", added_by: "UFF1")

    delete fd_case_thread_path(@root, thread)

    assert_nil Fd::CaseThread.find_by(id: thread.id), "detaching removes it"
  end

  def report_on(kase, who, at:)
    report = Fd::CaseReport.create!(case_id: kase.id, reporter_user_id: who,
      is_anonymous: false, body: "#{who} said something", source_app: "shroud", received_at: at)
    Fd::IntakeConversation.create!(report_id: report.id, member_user_id: who,
      channel_id: "D0#{who}", thread_ts: "1700.#{report.id}", opened_at: at)
    report
  end

  test "a reply goes to the thread you were reading, not the first one" do
    people = Fd::Member.order(:user_id).limit(2).pluck(:user_id)
    report_on(@root, people.first, at: 3.days.ago)
    theirs = report_on(@folded, people.last, at: 6.days.ago)
    conversation = Fd::IntakeConversation.find_by(report_id: theirs.id)

    post fd_case_replies_path(@root), params: { body: "we are on it",
      conversation_id: conversation.id }, as: :turbo_stream

    assert_equal conversation.id, Fd::IntakeOutbox.sole.conversation_id
  end

  def resolved_count
    Fd::CaseQuery.view_counts(nil)["resolved"]
  end

  test "the queue does not count a folded case as resolved work" do
    get fd_cases_path(view: "resolved")

    folded = resolved_count
    @folded.update!(duplicate_of: nil)

    assert_equal resolved_count - 1, folded, "a merge is filing, not an outcome"
  end

  test "a merge counts as neither a resolution nor a time to resolve" do
    start = Time.current.beginning_of_month
    @folded.update!(opened_at: start + 1.minute, resolved_at: start + 2.minutes)
    merged = Fd::QueueStats.load
    @folded.update!(duplicate_of: nil)
    loose = Fd::QueueStats.load

    assert_equal loose.opened_month_resolved - 1, merged.opened_month_resolved
    assert_not_equal loose.median_now, merged.median_now
    assert_equal loose.total, merged.total, "it is still a case that happened"
  end

  test "a case resolved on its own merits still counts" do
    folded = resolved_count
    @folded.update!(resolution: "no_action", duplicate_of: nil)

    assert_equal folded + 1, resolved_count
  end
end
