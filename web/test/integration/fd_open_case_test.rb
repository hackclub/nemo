require "test_helper"

class FdOpenCaseTest < ActionDispatch::IntegrationTest
  LINK = "https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456".freeze

  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @watermark = Fd::Case.maximum(:id).to_i
  end

  def open_case(**params)
    post fd_cases_path, params: {
      subject_user_id: "USUB", learned_from: "saw_it",
    }.merge(params)
  end

  def opened
    Fd::Case.where("id > ?", @watermark).order(:id).last
  end

  test "a signed out visitor cannot open a case" do
    open_case
    assert_redirected_to login_path
    assert_nil opened
  end

  test "the form is offered" do
    sign_in_as(@me)
    get new_fd_case_path

    assert_response :success
    assert_select "form[action=?]", fd_cases_path
    assert_select "input[name=subject_user_id]"
    assert_select "select[name=category_key]"
    assert_select "input[name=learned_from]", 4
  end

  test "opening records who opened it and when" do
    sign_in_as(@me)
    open_case(category_key: "bullying")

    kase = opened
    assert_equal "USUB", kase.subject_user_id
    assert_equal "bullying", kase.category_key
    assert_equal "saw_it", kase.learned_from
    assert_equal "UME", kase.opened_by
    assert_equal "fire_engine", kase.source_app
    assert_redirected_to fd_case_path(kase)
  end

  test "it joins the queue unassigned unless I say otherwise" do
    sign_in_as(@me)
    open_case
    assert_nil opened.claimed_by

    open_case(assign_to_me: "1")
    assert_equal "UME", opened.claimed_by
    assert_not_nil opened.claimed_at
  end

  test "a case needs somebody to be about" do
    sign_in_as(@me)
    open_case(subject_user_id: "  ")

    assert_nil opened
    assert_response :unprocessable_content
    assert_match(/say who this case is about/, flash[:alert])
  end

  test "how you learned about it is required, and must be one of the four" do
    sign_in_as(@me)
    open_case(learned_from: "")
    assert_nil opened

    open_case(learned_from: "a little bird")
    assert_nil opened
    assert_match(/say how you learned about it/, flash[:alert])
  end

  test "a category outside the list is refused" do
    sign_in_as(@me)
    open_case(category_key: "vibes")

    assert_nil opened
    assert_match(/pick a category from the list/, flash[:alert])
  end

  test "no category at all is allowed" do
    sign_in_as(@me)
    open_case(category_key: "")
    assert_nil opened.category_key
  end

  test "what happened is filed as the first note" do
    sign_in_as(@me)
    open_case(body: "saw this live in the lounge")

    note = opened.notes.sole
    assert_equal "saw this live in the lounge", note.body
    assert_equal "UME", note.author
  end

  test "a thread can be attached as it opens, and becomes primary" do
    sign_in_as(@me)
    open_case(link: LINK)

    thread = opened.threads.sole
    assert_equal "C0266FRGV", thread.channel_id
    assert_equal "1754487721.123456", thread.thread_ts
    assert_equal "evidence", thread.kind
    assert thread.is_primary
  end

  test "an internal first thread is never primary" do
    sign_in_as(@me)
    open_case(link: LINK, kind: "internal")

    thread = opened.threads.sole
    assert thread.internal?
    assert_not thread.is_primary
  end

  test "a bad link refuses the whole thing rather than opening a half case" do
    sign_in_as(@me)
    open_case(link: "https://someoneelse.slack.com/archives/C1/p1754487721123456", body: "text")

    assert_nil opened, "nothing should be created when part of the form is wrong"
    assert_match(/not a link to a Slack thread/, flash[:alert])
  end

  test "opening with no thread and no note still works" do
    sign_in_as(@me)
    open_case

    assert_not_nil opened
    assert_equal 0, opened.threads.count
    assert_equal 0, opened.notes.count
  end

  test "the case, its thread and its note share one request in the trail" do
    sign_in_as(@me)
    open_case(link: LINK, body: "context")

    kase = opened
    ids = Fd::AuditEntry.where(
      "(entity_type = 'case' AND entity_id = ?) OR (entity_type = 'thread' AND entity_id IN (?))" \
      " OR (entity_type = 'note' AND entity_id IN (?))",
      kase.id, kase.threads.ids, kase.notes.ids
    ).pluck(:request_id).uniq

    assert_equal 1, ids.size
    assert_not_nil ids.first
  end

  test "the note text is summarised in the trail, never copied" do
    sign_in_as(@me)
    open_case(body: "he mentioned self harm")

    entry = Fd::AuditEntry.where(entity_type: "note", entity_id: opened.notes.ids, verb: "noted").sole
    assert_equal "redacted, 22 chars", entry.after["body"]
    assert_no_match(/self harm/, entry.after.to_json)
  end

  test "the queue links to the form" do
    sign_in_as(@me)
    get fd_cases_path
    assert_select "a[href=?]", new_fd_case_path, text: "Open a case"
  end
end
