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
    assert_select ".line-row .chip", text: "shush"
  end

  test "the folded case's notes show, and the count includes them" do
    Fd::Note.create!(case_id: @folded.id, body: "came in twice", author: "UFF1")
    get fd_case_path(@root, tab: "notes")

    assert_select ".note-body", text: "came in twice"
  end

  test "the folded case's evidence threads show" do
    Fd::CaseThread.create!(case_id: @folded.id, channel_id: "C0LOUNGE", thread_ts: "1700.1",
      kind: "evidence", added_by: "UFF1")
    get fd_case_path(@root, tab: "evidence")

    assert_select "body", text: /C0LOUNGE/
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

    assert_select ".chip", text: "from ##{@folded.id}"
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
end
