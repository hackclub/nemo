require "test_helper"

class FdOpenCaseTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    @watermark = Fd::Case.maximum(:id).to_i
  end

  def open_case(**params)
    post fd_cases_path, params: { subject_user_id: "USUB", body: "saw it live" }.merge(params)
  end

  def opened
    Fd::Case.where("id > ?", @watermark).where(opened_by: @me.user_id).order(:id).last
  end

  test "cases create signed out redirects to login and opens no case" do
    open_case
    assert_redirected_to login_path
    assert_nil opened
  end

  test "cases index returns success for community manager" do
    sign_in_as(@me)
    get fd_cases_path

    assert_response :success
  end

  test "cases create stores the case fields and redirects to the case" do
    sign_in_as(@me)
    open_case(category_key: "bullying")

    kase = opened
    assert_equal "USUB", kase.subject_user_id
    assert_equal "bullying", kase.category_key
    assert_equal "UME", kase.opened_by
    assert_equal "fire_engine", kase.source_app
    assert_redirected_to fd_case_path(kase)
  end

  test "cases create without assign_to_me leaves the case unassigned" do
    sign_in_as(@me)
    open_case
    assert_not opened.assigned?
  end

  test "cases create with assign_to_me assigns the current user" do
    sign_in_as(@me)
    open_case(assign_to_me: "1")

    assert_equal ["UME"], opened.assignee_user_ids
    assert_equal "UME", opened.assignees.sole.assigned_by
  end

  test "cases create with blank subject_user_id opens a case with no subjects" do
    sign_in_as(@me)
    open_case(subject_user_id: "  ")

    kase = opened
    assert_not_nil kase
    assert_empty kase.subject_user_ids
    assert_redirected_to fd_case_path(kase)
  end

  test "cases create with an unknown category_key opens no case and alerts" do
    sign_in_as(@me)
    open_case(category_key: "vibes")

    assert_nil opened
    assert_match(/Select a category/, flash[:alert])
  end

  test "cases create with blank category_key stores nil category_key" do
    sign_in_as(@me)
    open_case(category_key: "")
    assert_nil opened.category_key
  end

  test "cases create stores body as a card case chat message and no note" do
    sign_in_as(@me)
    open_case(body: "saw this live in the lounge")

    first = Fd::CaseChat.where(case_id: opened.id).sole
    assert_equal "saw this live in the lounge", first.body
    assert_equal "UME", first.author_user_id
    assert_equal "card", first.mirrored_as
    assert_equal 0, opened.notes.count
  end

  test "cases create with blank body opens no case and alerts" do
    sign_in_as(@me)
    open_case(body: "  ")

    assert_nil opened
    assert_match(/Enter a description/, flash[:alert])
  end

  test "cases create ignores the link param and attaches no thread" do
    sign_in_as(@me)
    open_case(link: "https://hackclub.slack.com/archives/C0266FRGV/p1754487721123456")

    assert_not_nil opened
    assert_equal 0, opened.threads.count, "thread attached from the link param"
  end

  test "cases create with subject and body attaches no threads and no notes" do
    sign_in_as(@me)
    open_case

    assert_not_nil opened
    assert_equal 0, opened.threads.count
    assert_equal 0, opened.notes.count
  end

  test "cases create keeps body out of the opened audit entry" do
    sign_in_as(@me)
    open_case(body: "he mentioned self harm")

    entries = Fd::AuditEntry.where(request_id: Fd::AuditEntry
      .where(entity_type: "case", entity_id: opened.id, verb: "opened").select(:request_id))
    assert_no_match(/self harm/, entries.map { |entry| entry.after.to_json }.join)
  end

  test "cases create with several subject_user_ids stores all subjects and flashes the count" do
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: %w[UONE UTWO UTHREE], body: "saw it live" }

    kase = Fd::Case.order(:id).last
    assert_equal %w[UONE UTHREE UTWO], kase.subject_user_ids
    assert_match(/opened · 3 subjects/, flash[:notice])
  end

  test "cases create writes one attached audit entry per subject with one request_id" do
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: %w[UONE UTWO], body: "saw it live" }

    kase = Fd::Case.order(:id).last
    rows = Fd::AuditEntry.where(entity_type: "participant", entity_id: kase.id, verb: "attached")
    assert_equal 2, rows.count
    assert_equal %w[UONE UTWO], rows.map { |row| row.after["user_id"] }.sort
    assert_equal 1, rows.pluck(:request_id).uniq.size
  end

  test "cases create with one invalid subject id opens no case and alerts" do
    sign_in_as(@me)
    before = Fd::Case.count
    post fd_cases_path, params: { subject_user_ids: %w[UONE bob], body: "saw it live" }

    assert_equal before, Fd::Case.count
    assert_match(/Not a Slack member ID/, flash[:alert])
  end

  test "cases create with a duplicate subject_user_id stores one subject" do
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: %w[UONE UONE], body: "saw it live" }

    assert_equal ["UONE"], Fd::Case.order(:id).last.subject_user_ids
  end

  test "cases create with a subject that has an open case opens the case with no alert" do
    make_case(subject: "UTWO", opened_at: 3.days.ago)
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: %w[UONE UTWO], body: "saw it live" }

    assert_not_nil opened
    assert_nil flash[:alert]
    assert_redirected_to fd_case_path(opened)
  end

  test "cases create for a subject with an open case opens a second case" do
    make_case(opened_at: 3.days.ago, category_key: "bullying")
    sign_in_as(@me)
    open_case

    assert_not_nil opened
    assert_equal "USUB", opened.subject_user_id
    assert_equal 2, Fd::Case.unresolved.with_subject("USUB").count
  end

  test "cases create for a subject with a resolved case opens a case" do
    make_case(opened_at: 5.days.ago, resolved_at: 1.day.ago, resolution: "no_action")
    sign_in_as(@me)
    open_case

    assert_not_nil opened, "no case opened for a subject with a resolved case"
  end

  test "cases create opens a case when another subject has an open case" do
    make_case(subject: "UELSE", opened_at: 3.days.ago)
    sign_in_as(@me)
    open_case

    assert_not_nil opened
  end

  test "cases create with assign_to_me 0 opens the case unassigned" do
    sign_in_as(@me)
    post fd_cases_path, params: { subject_user_ids: ["USUB"], body: "said it again",
                                  assign_to_me: "0" }

    assert_empty Fd::Case.order(:id).last.assignees,
      "case has assignees with assign_to_me 0"
  end
end
