require "test_helper"

class FdMergedCaseTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
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

  test "the folded case's actions show on the case that holds it" do
    act_on(@folded, type_key: "shush", expires_at: 3.days.from_now)
    get fd_case_path(@root, tab: "actions")

    assert_response :success
    assert_select ".ledger-top b", text: "Shush"
  end

  test "the folded case's notes show, and the count includes them" do
    Fd::Note.create!(case_id: @folded.id, body: "came in twice", author: "UFF1")
    get fd_case_path(@root, tab: "notes")

    assert_select ".note-body", text: "came in twice"
  end

  test "the folded case's evidence threads show" do
    thread = Fd::CaseThread.create!(case_id: @folded.id, channel_id: "C0LOUNGE",
      thread_ts: "1700.1", kind: "evidence", added_by: "UFF1")
    get fd_case_path(@root, tab: "evidence")

    assert_select "a[href*=?]", "thread=#{thread.id}"
  end

  test "the same person on both cases is listed once, not twice" do
    @folded.participants.create!(user_id: "UWITNESS", role: "involved", detail: "saw it")
    @root.participants.create!(user_id: "UWITNESS", role: "involved", detail: "saw it")

    get fd_case_path(@root, tab: "people")

    assert_select ".people-list .person-row", 2, "the subject and the witness, once each"
  end

  test "the timeline says which case an entry came from" do
    act_on(@folded)
    get fd_case_path(@root)

    assert_select ".tl-item .tl-detail", { text: /from ##{@folded.id}/ },
      "an entry carried over from a folded case says where it came from"
  end

  test "the timeline says nothing extra for the case's own entries" do
    act_on(@root)
    get fd_case_path(@root)

    assert_select ".chip", text: "from ##{@root.id}", count: 0
  end

  test "a case with nothing merged into it is unchanged" do
    alone = make_case(subject: "UOTHER", opened_at: 3.days.ago)
    act_on(alone)

    get fd_case_path(alone)
    assert_response :success
    assert_select ".chip", text: /\Afrom #/, count: 0
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

  test "one report means no thread pills at all" do
    who = Fd::Member.first.user_id
    report_on(@root, who, at: 3.days.ago)

    get fd_case_path(@root)
    assert_select ".chat-picks", 0
    assert_select ".chat-head b"
  end

  test "two reports give a pill each, and the folded one says where it came from" do
    people = Fd::Member.order(:user_id).limit(2).pluck(:user_id)
    mine = report_on(@root, people.first, at: 3.days.ago)
    theirs = report_on(@folded, people.last, at: 6.days.ago)

    get fd_case_path(@root)

    assert_select ".chat-picks .chat-pick", 2
    assert_select ".chat-pick[aria-current]", 1
    assert_select ".chat-pick-from", text: "from ##{@folded.id}"
    assert_not_nil mine
    assert_not_nil theirs
  end

  test "the thread you pick is the conversation you see" do
    people = Fd::Member.order(:user_id).limit(2).pluck(:user_id)
    mine = report_on(@root, people.first, at: 3.days.ago)
    theirs = report_on(@folded, people.last, at: 6.days.ago)

    get fd_case_path(@root, thread: theirs.id)
    assert_select ".chat-log .said-body", text: /#{people.last} said something/
    assert_select ".chat-log .said-body", text: /#{people.first} said something/, count: 0

    get fd_case_path(@root, thread: mine.id)
    assert_select ".chat-log .said-body", text: /#{people.first} said something/
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
    assert_select ".two-line b", text: /#{@folded.id}/, count: 0

    folded = resolved_count
    @folded.update!(duplicate_of: nil)

    assert_equal resolved_count - 1, folded, "a merge is filing, not an outcome"
  end

  test "a folded case still shows in everything, saying where it went" do
    get fd_cases_path(view: "everything")

    assert_select ".two-line span", text: /merged into ##{@root.id}/
    assert_select "a.row-merged[href=?]", fd_case_path(@root)
    assert_select ".two-line b", text: /#{@folded.id}/
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

  test "the internal chat shows in whichever thread you are reading" do
    people = Fd::Member.order(:user_id).limit(2).pluck(:user_id)
    report_on(@root, people.first, at: 3.days.ago)
    theirs = report_on(@folded, people.last, at: 6.days.ago)
    Fd::CaseChat.create!(case_id: @root.id, author_user_id: "UME", body: "same person as both",
      source_app: "fire_engine")

    get fd_case_path(@root, thread: theirs.id)
    assert_select ".chat-log .said-body", text: "same person as both"
  end
end
