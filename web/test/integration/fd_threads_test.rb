require "test_helper"

class FdThreadsTest < ActionDispatch::IntegrationTest
  LINK = "https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456".freeze

  setup do
    @me = hold_role!("UME", "community_manager")
    @kase = make_case
  end

  def attach(**params)
    post fd_case_threads_path(@kase), params: { link: LINK }.merge(params)
  end

  def threads
    @kase.threads
  end

  def entries(verb)
    Fd::AuditEntry.where(entity_type: "thread", verb: verb)
  end

  test "a signed out visitor cannot attach a thread" do
    attach
    assert_redirected_to login_path
    assert_equal 0, threads.count
  end

  test "attaching parses the link into coordinates" do
    sign_in_as(@me)
    attach

    thread = threads.sole
    assert_equal "C0266FRGV", thread.channel_id
    assert_equal "1754487721.123456", thread.thread_ts
    assert_equal "evidence", thread.kind
    assert_equal "UME", thread.added_by
    assert_match(/evidence thread attached/, flash[:notice])
  end

  test "the first evidence thread becomes the primary one" do
    sign_in_as(@me)
    attach
    assert threads.sole.is_primary
  end

  test "a second evidence thread does not steal primary" do
    sign_in_as(@me)
    attach
    attach(link: LINK.sub("p1754487721123456", "p1800000000000001"))

    assert_equal 1, threads.where(is_primary: true).count
    assert_equal "1754487721.123456", threads.find_by(is_primary: true).thread_ts
  end

  test "an internal thread is never primary" do
    sign_in_as(@me)
    attach(kind: "internal")

    thread = threads.sole
    assert thread.internal?
    assert_not thread.is_primary, "an FD discussion cannot be what the case is about"
    assert_match(/not evidence/, flash[:notice])
  end

  test "an internal thread first still leaves the next evidence thread primary" do
    sign_in_as(@me)
    attach(kind: "internal")
    attach(link: LINK.sub("p1754487721123456", "p1800000000000001"), kind: "evidence")

    assert threads.evidence.sole.is_primary
  end

  test "a kind nobody offered falls back to evidence" do
    sign_in_as(@me)
    attach(kind: "deliberation")
    assert_equal "evidence", threads.sole.kind
  end

  test "junk in the link box is refused without a crash" do
    sign_in_as(@me)
    ["", "not a url", "https://someoneelse.slack.com/archives/C1/p1754487721123456",
     "https://hackclub.slack.com.evil.test/archives/C1/p1754487721123456"].each do |input|
      attach(link: input)
      assert_equal 0, threads.count, "#{input.inspect} must not attach"
      assert_match(/paste a link to a Slack thread/, flash[:alert])
    end
  end

  test "a reply link attaches the thread it belongs to" do
    sign_in_as(@me)
    attach(link: "#{LINK.sub('p1754487721123456', 'p1754499999000001')}?thread_ts=1754487721.123456")
    assert_equal "1754487721.123456", threads.sole.thread_ts
  end

  test "attaching the same thread twice is refused, not duplicated" do
    sign_in_as(@me)
    attach
    attach

    assert_equal 1, threads.count
    assert_match(/already on this case/, flash[:alert])
  end

  test "the same thread can sit on two different cases" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    sign_in_as(@me)
    attach
    post fd_case_threads_path(other), params: { link: LINK }

    assert_equal 1, threads.count
    assert_equal 1, other.threads.count
    assert_equal [other.id], @kase.sibling_cases.pluck(:id),
      "two cases citing one evidence thread are siblings"
  end

  test "I can attach to a case assigned to somebody else" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    attach

    assert_equal 1, threads.count
  end

  test "attaching is recorded in the trail" do
    sign_in_as(@me)
    attach

    entry = entries("attached").sole
    assert_equal "UME", entry.actor_user_id
    assert_equal "C0266FRGV", entry.after["channel_id"]
    assert_equal "evidence", entry.after["kind"]
  end

  test "detaching removes the row and records which one it was" do
    sign_in_as(@me)
    attach
    thread = threads.sole

    delete fd_case_thread_path(@kase, thread)

    assert_equal 0, threads.count
    entry = entries("detached").sole
    assert_equal "C0266FRGV", entry.before["channel_id"]
    assert_equal "1754487721.123456", entry.before["thread_ts"]
    assert_match(/Thread taken off case/, flash[:notice])
    assert_match(/messages stay in Slack/, flash[:said])
  end

  test "a thread on another case cannot be detached through this one" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    theirs = Fd::CaseThread.create!(case_id: other.id, channel_id: "C9", thread_ts: "9.9",
      added_by: "UFF1")

    sign_in_as(@me)
    delete fd_case_thread_path(@kase, theirs)

    assert_equal 1, other.threads.count, "the case in the url must own the thread"
    assert_match(/not on this case/, flash[:alert])
  end

  test "I can detach from a case assigned to somebody else" do
    thread = Fd::CaseThread.create!(case_id: @kase.id, channel_id: "C1", thread_ts: "1.1",
      added_by: "UFF1")
    @kase.assign!("UOTHER")

    sign_in_as(@me)
    delete fd_case_thread_path(@kase, thread)

    assert_equal 0, threads.count
  end

  test "the page offers the attach modal and a detach control per row" do
    sign_in_as(@me)
    attach
    get fd_case_path(@kase, tab: "evidence")

    assert_select "input#attach-thread.modal-flip"
    assert_select "form[action=?] input[name=link]", fd_case_threads_path(@kase)
    assert_select "input[name=kind][value=evidence]"
    assert_select "input[name=kind][value=internal]"
    assert_select ".menu-pop .mi-t", text: "Detach this thread", count: 1
  end
end
