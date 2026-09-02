require "test_helper"

class FdMemberRecordTest < ActionDispatch::IntegrationTest
  SUBJECT = "UPRIOR".freeze

  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def act_on(kase, target: SUBJECT, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: target,
                         decided_by: "UFF1", performed_by: "UFF1" }.merge(attrs))
  end

  test "a member with nothing on them still gets a page" do
    get fd_member_path("UNOBODY")

    assert_response :success
    assert_select ".record-row", 0
    assert_select ".empty-title"
  end

  test "the priors figure uses the definition, not the case count" do
    acted = make_case(subject: SUBJECT, opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "action_taken")
    act_on acted
    make_case(subject: SUBJECT, opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "no_action")
    make_case(subject: SUBJECT, opened_at: 2.days.ago)

    assert_equal 1, Fd::Case.prior_count(SUBJECT, within: Fd::Case::PRIOR_WINDOW)
  end

  test "a timed action still running leads the record" do
    kase = make_case(subject: SUBJECT, opened_at: 3.days.ago)
    act_on kase, type_key: "shush", expires_at: 4.days.from_now

    get fd_member_path(SUBJECT)

    assert_select ".standing .standing-t", text: "In force now"
    assert_select ".standing .standing-line", text: /Shush until/
    assert_select ".standing a[href=?]", fd_case_path(kase)
  end

  test "an action with no due date never leads the record, but stays on it" do
    kase = make_case(subject: SUBJECT, opened_at: 3.days.ago)
    act_on kase, type_key: "warning"

    get fd_member_path(SUBJECT)

    assert_select ".standing", 0, "a warning is not being enforced over time"
    assert_select ".record-row", 2, "the case and the warning are still on the record"
  end

  test "an action past its expiry drops out of force without leaving the record" do
    kase = make_case(subject: SUBJECT, opened_at: 30.days.ago)
    act_on kase, type_key: "shush", expires_at: 1.day.ago

    get fd_member_path(SUBJECT)

    assert_select ".standing", 0
    assert_select ".record-row", 2
  end

  test "the identity line says email is not collected rather than showing a blank" do
    get fd_member_path("UNOBODY")
    assert_select ".locked", text: /Nothing on file|Email not collected yet/
  end

  test "looking at a member writes an access log row against me" do
    before = AccessLog.count
    get fd_member_path(SUBJECT)

    assert_equal before + 1, AccessLog.count
    entry = AccessLog.order(:id).last
    assert_equal "UME", entry.actor_id
    assert_equal SUBJECT, entry.subject_user_id
  end

  test "a signed out visitor sees nothing and logs nothing" do
    delete logout_path
    before = AccessLog.count
    get fd_member_path(SUBJECT)

    assert_redirected_to login_path
    assert_equal before, AccessLog.count, "a refused request must not record a lookup"
  end

  test "the record lists every case and action, newest first" do
    old = make_case(subject: SUBJECT, opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "action_taken")
    act_on old, performed_at: 31.days.ago
    recent = make_case(subject: SUBJECT, opened_at: 2.days.ago)

    get fd_member_path(SUBJECT)

    assert_select ".record-row", 3
    assert_select ".record-row:first-of-type a[href=?]", fd_case_path(recent)
    assert_select ".record-list a[href=?]", fd_case_path(old)
  end

  test "each tab narrows the record to its own kind" do
    kase = make_case(subject: SUBJECT, opened_at: 10.days.ago)
    act_on kase, performed_at: 3.days.ago
    Fd::Note.create!(subject_user_id: SUBJECT, body: "watch this one", author: "UFF1")

    get fd_member_path(SUBJECT)
    assert_select ".record-row", 3

    get fd_member_path(SUBJECT, show: "actions")
    assert_select ".record-row", 1
    assert_select ".segmented a[aria-current]", text: /Actions/

    get fd_member_path(SUBJECT, show: "notes")
    assert_select ".record-row", 1
    assert_select ".segmented a[aria-current]", text: /Notes/
  end

  test "a tab that matches nothing says which nothing it is" do
    make_case(subject: SUBJECT, opened_at: 10.days.ago)
    get fd_member_path(SUBJECT, show: "actions")

    assert_select ".record-row", 0
    assert_select ".empty-title", text: /Nothing has ever been done to them/
  end

  test "the composer only sits on the tab that holds the notes" do
    get fd_member_path(SUBJECT)
    assert_select "form[action=?]", fd_member_notes_path(SUBJECT), count: 0

    get fd_member_path(SUBJECT, show: "notes")
    assert_select "form[action=?] textarea[name=body]", fd_member_notes_path(SUBJECT)
  end

  test "a note written here follows the member rather than a case" do
    post fd_member_notes_path(SUBJECT), params: { body: "escalates in public" }

    note = Fd::Note.for_subject(SUBJECT).sole
    assert_nil note.case_id, "a standing note belongs to the member, not a case"
    assert_equal "UME", note.author
    assert_match(/follows them to every case/, flash[:notice])
    assert_redirected_to fd_member_path(SUBJECT, show: "notes")
  end

  test "an empty note is refused here too" do
    post fd_member_notes_path(SUBJECT), params: { body: "   " }

    assert_empty Fd::Note.for_subject(SUBJECT).to_a
    assert_nil flash[:alert], "a problem with one field is not a page-level message"
    assert_equal "body", flash[:wrong]["field"]
    assert_match(/Write the note/i, flash[:wrong]["said"])

    follow_redirect!
    assert_select ".panel-foot .field-wrong", text: /Write the note/i
  end

  test "the note text never reaches the trail, only its length" do
    post fd_member_notes_path(SUBJECT), params: { body: "he mentioned self harm" }

    entry = Fd::AuditEntry.where(entity_type: "note", verb: "noted").order(:id).last
    assert_equal "redacted, 22 chars", entry.after["body"]
    assert_no_match(/self harm/, entry.after.to_json)
  end

  test "I can remove my own standing note and nobody else's" do
    post fd_member_notes_path(SUBJECT), params: { body: "mine to remove" }
    mine = Fd::Note.for_subject(SUBJECT).sole
    theirs = Fd::Note.create!(subject_user_id: SUBJECT, body: "not mine", author: "UFF9")

    delete fd_member_note_path(SUBJECT, theirs)
    assert_nil theirs.reload.deleted_at
    assert_match(/only whoever wrote a note can remove it/, flash[:alert])

    delete fd_member_note_path(SUBJECT, mine)
    assert_not_nil mine.reload.deleted_at
  end

  test "opening a case from here arrives with the modal open and the subject filled" do
    get fd_cases_path(subject_user_id: SUBJECT, open: "1")

    assert_select "input#open-case[checked]"
    assert_select ".pick[data-member-picker-preset-value*=?]", SUBJECT
  end
end
