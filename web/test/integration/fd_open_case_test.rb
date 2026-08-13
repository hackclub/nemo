require "test_helper"

class FdOpenCaseTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @watermark = Fd::Case.maximum(:id).to_i
  end

  def open_case(**params)
    post fd_cases_path, params: { subject_user_id: "USUB" }.merge(params)
  end

  def opened
    Fd::Case.where("id > ?", @watermark).where(opened_by: @me.user_id).order(:id).last
  end

  test "a signed out visitor cannot open a case" do
    open_case
    assert_redirected_to login_path
    assert_nil opened
  end

  test "the queue carries the form in a modal, closed by default" do
    sign_in_as(@me)
    get fd_cases_path

    assert_response :success
    assert_select "label[for=open-case]", text: "Open a case"
    assert_select "input#open-case.modal-flip"
    assert_select "input#open-case[checked]", count: 0
    assert_select "form[action=?] input[name=subject_user_id]", fd_cases_path
    assert_select "form[action=?] .picker input[name=category_key]", fd_cases_path,
      minimum: Fd::Case::CATEGORIES.size
    assert_select "select[name=category_key]", count: 0,
      message: "the category picker should not be a native select"
  end

  test "opening records who opened it and when" do
    sign_in_as(@me)
    open_case(category_key: "bullying")

    kase = opened
    assert_equal "USUB", kase.subject_user_id
    assert_equal "bullying", kase.category_key
    assert_equal "UME", kase.opened_by
    assert_equal "fire_engine", kase.source_app
    assert_redirected_to fd_case_path(kase)
  end

  test "it joins the queue unassigned by default" do
    sign_in_as(@me)
    open_case
    assert_nil opened.claimed_by
  end

  test "it can be assigned to me as it opens" do
    sign_in_as(@me)
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

  test "the modal asks for no thread at all, threads are attached on the case" do
    sign_in_as(@me)
    get fd_cases_path

    assert_select "form[action=?] input[name=link]", fd_cases_path, count: 0
    assert_select "form[action=?] input[name=kind]", fd_cases_path, count: 0
  end

  test "a posted thread link is ignored" do
    sign_in_as(@me)
    open_case(link: "https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456")

    assert_not_nil opened
    assert_equal 0, opened.threads.count, "the form does not take a thread, so none is attached"
  end

  test "a case opens with nothing but a subject" do
    sign_in_as(@me)
    open_case

    assert_not_nil opened
    assert_equal 0, opened.threads.count
    assert_equal 0, opened.notes.count
  end

  test "the case and its note share one request in the trail" do
    sign_in_as(@me)
    open_case(body: "context")

    kase = opened
    ids = Fd::AuditEntry.where(
      "(entity_type = 'case' AND entity_id = ?) OR (entity_type = 'note' AND entity_id IN (?))",
      kase.id, kase.notes.ids
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

  test "a subject with an open case stops the first submit" do
    existing = make_case(opened_at: 3.days.ago, category_key: "bullying")
    sign_in_as(@me)
    open_case

    assert_nil opened, "nothing is created until it is confirmed as separate"
    assert_response :unprocessable_content
    assert_match(/already has an open case, ##{existing.id}/, flash[:alert])
  end

  test "the warning names the case, its state and a way to reach it" do
    existing = make_case(opened_at: 3.days.ago, category_key: "bullying", claimed_by: "UFF2",
      claimed_at: 2.days.ago)
    sign_in_as(@me)
    open_case

    assert_select ".dup a[href=?]", fd_case_path(existing)
    assert_match(/assigned to @UFF2/, response.body)
    assert_select ".dup a", text: "Add to ##{existing.id} instead"
  end

  test "confirming it is separate opens the second case" do
    make_case(opened_at: 3.days.ago)
    sign_in_as(@me)
    open_case(separate: "1")

    assert_not_nil opened
    assert_equal "USUB", opened.subject_user_id
    assert_equal 2, Fd::Case.unresolved.with_subject("USUB").count
  end

  test "what I typed survives the warning" do
    make_case(opened_at: 3.days.ago)
    sign_in_as(@me)
    open_case(category_key: "spam", body: "third time this week")

    assert_select "input#open-case[checked]", message: "the modal must reopen with the warning"
    assert_select "input[name=subject_user_id][value=USUB]"
    assert_select ".picker input[name=category_key][value=spam][checked]"
    assert_select "textarea[name=body]", text: /third time this week/
  end

  test "the confirm button replaces the plain one once warned" do
    make_case(opened_at: 3.days.ago)
    sign_in_as(@me)
    open_case

    assert_select "button[name=separate][value='1']"
    assert_select "input[type=submit][value='Open the case']", count: 0
  end

  test "a resolved case for the same subject raises no warning" do
    make_case(opened_at: 5.days.ago, resolved_at: 1.day.ago, resolution: "no_action")
    sign_in_as(@me)
    open_case

    assert_not_nil opened, "a closed case is not a reason to stop"
  end

  test "somebody else's open case is not a reason to stop" do
    make_case(subject: "UELSE", opened_at: 3.days.ago)
    sign_in_as(@me)
    open_case

    assert_not_nil opened
  end

  test "the queue still lists cases behind the warning" do
    make_case(opened_at: 3.days.ago)
    sign_in_as(@me)
    open_case

    assert_select ".data-table tbody tr", minimum: 1
    assert_select "form#merge-form"
  end
end
