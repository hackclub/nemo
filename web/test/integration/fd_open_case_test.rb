require "test_helper"

class FdOpenCaseTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
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
    assert_select "button[data-modal-open=open-case]", text: "Open a case"
    assert_select "input#open-case.modal-flip"
    assert_select "input#open-case[checked]", count: 0
    assert_select "form[action=?] .pick[data-member-picker-name-value='subject_user_ids[]']",
      fd_cases_path
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
    assert_not opened.assigned?
  end

  test "it can be assigned to me as it opens" do
    sign_in_as(@me)
    open_case(assign_to_me: "1")

    assert_equal ["UME"], opened.assignee_user_ids
    assert_equal "UME", opened.assignees.sole.assigned_by
  end

  test "a case can be opened with nobody identified as the subject yet" do
    sign_in_as(@me)
    open_case(subject_user_id: "  ")

    kase = opened
    assert_not_nil kase
    assert_empty kase.subject_user_ids
    assert_redirected_to fd_case_path(kase)
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

  test "a case can be opened about several people at once" do
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: %w[UONE UTWO UTHREE] }

    kase = Fd::Case.order(:id).last
    assert_equal %w[UONE UTHREE UTWO], kase.subject_user_ids
    assert_match(/opened, about 3 people/, flash[:notice])
  end

  test "each subject gets its own trail entry, under the one request" do
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: %w[UONE UTWO] }

    kase = Fd::Case.order(:id).last
    rows = Fd::AuditEntry.where(entity_type: "participant", entity_id: kase.id, verb: "attached")
    assert_equal 2, rows.count
    assert_equal %w[UONE UTWO], rows.map { |row| row.after["user_id"] }.sort
    assert_equal 1, rows.pluck(:request_id).uniq.size
  end

  test "one bad id refuses the whole case rather than opening a half one" do
    sign_in_as(@me)
    before = Fd::Case.count
    post fd_cases_path, params: { subject_user_ids: %w[UONE bob] }

    assert_equal before, Fd::Case.count
    assert_match(/does not look like a Slack member id/, flash[:alert])
  end

  test "the same person named twice is one subject, not two" do
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: %w[UONE UONE] }

    assert_equal ["UONE"], Fd::Case.order(:id).last.subject_user_ids
  end

  test "an open case for any of the people named raises the warning" do
    existing = make_case(subject: "UTWO", opened_at: 3.days.ago)
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: %w[UONE UTWO] }

    assert_response :unprocessable_content
    assert_match(/@UTWO already has an open case, ##{existing.id}/, flash[:alert])
  end

  test "the warning names everybody it caught, not just the first" do
    make_case(subject: "UONE", opened_at: 4.days.ago)
    make_case(subject: "UTWO", opened_at: 3.days.ago)
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: %w[UONE UTWO] }

    assert_match(/@UONE and @UTWO already have an open case/, flash[:alert])
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
    existing = make_case(opened_at: 3.days.ago, category_key: "bullying", assign: "UFF2")
    sign_in_as(@me)
    open_case

    assert_select ".dup a[href=?]", fd_case_path(existing)
    assert_match(/assigned to @UFF2/, response.body)
    assert_select ".modal-foot a", text: "Add to ##{existing.id} instead",
      count: 1
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
    assert_select ".pick[data-member-picker-preset-value*=USUB]",
      message: "the person I picked must still be picked after the warning"
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

    assert_select "tbody tr", minimum: 1
    assert_select "form#merge-form"
  end

  test "the modal offers to assign it to you by default" do
    sign_in_as(@me)
    get fd_cases_path(open: "1")

    assert_select "#open-case ~ * input[name=assign_to_me][type=checkbox][checked]", 1,
      "an unassigned case is nobody's job, so the box starts ticked"
  end

  test "unticking it still opens the case unassigned" do
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: ["USUB"], body: "said it again",
                                  assign_to_me: "0" }

    assert_empty Fd::Case.order(:id).last.assignees,
      "an explicit untick must not be overridden by the default"
  end
end
