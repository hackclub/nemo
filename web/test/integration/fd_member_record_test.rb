require "test_helper"

class FdMemberRecordTest < ActionDispatch::IntegrationTest
  SUBJECT = "UPRIOR".freeze

  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def act_on(kase, target: SUBJECT, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: target,
                         decided_by: "UFF1", performed_by: "UFF1" }.merge(attrs))
  end

  test "show for a member with no records returns success" do
    get fd_member_path("UNOBODY")

    assert_response :success
  end

  test "Case.prior_count excludes open and no_action cases" do
    action_taken_case = make_case(subject: SUBJECT, opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "action_taken")
    act_on action_taken_case
    make_case(subject: SUBJECT, opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "no_action")
    make_case(subject: SUBJECT, opened_at: 2.days.ago)

    assert_equal 1, Fd::Case.prior_count(SUBJECT, within: Fd::Case::PRIOR_WINDOW)
  end

  test "show writes one access log row with actor and subject" do
    before = AccessLog.count
    get fd_member_path(SUBJECT)

    assert_equal before + 1, AccessLog.count
    entry = AccessLog.order(:id).last
    assert_equal "UME", entry.actor_id
    assert_equal SUBJECT, entry.subject_user_id
  end

  test "show signed out redirects to login and writes no access log row" do
    delete logout_path
    before = AccessLog.count
    get fd_member_path(SUBJECT)

    assert_redirected_to login_path
    assert_equal before, AccessLog.count, "a refused request must not record a lookup"
  end

  test "create note stores a member note with no case_id" do
    post fd_member_notes_path(SUBJECT), params: { body: "escalates in public" }

    note = Fd::Note.for_subject(SUBJECT).sole
    assert_nil note.case_id, "a standing note belongs to the member, not a case"
    assert_equal "UME", note.author
    assert_equal "Note added", flash[:notice]
    assert_redirected_to fd_member_path(SUBJECT)
  end

  test "create note with blank body stores nothing and sets a body field_error" do
    post fd_member_notes_path(SUBJECT), params: { body: "   " }

    assert_empty Fd::Note.for_subject(SUBJECT).to_a
    assert_nil flash[:alert], "a problem with one field is not a page-level message"
    assert_equal "body", flash[:field_error]["field"]
    assert_match(/Enter the note/i, flash[:field_error]["message"])
    assert_redirected_to fd_member_path(SUBJECT)
  end

  test "create note audit entry redacts the body to its length" do
    post fd_member_notes_path(SUBJECT), params: { body: "he mentioned self harm" }

    entry = Fd::AuditEntry.where(entity_type: "note", verb: "noted").order(:id).last
    assert_equal "redacted, 22 chars", entry.after["body"]
    assert_no_match(/self harm/, entry.after.to_json)
  end

  test "member note remove sets deleted_at on own and other authors notes" do
    post fd_member_notes_path(SUBJECT), params: { body: "mine to remove" }
    own_note = Fd::Note.for_subject(SUBJECT).sole
    other_note = Fd::Note.create!(subject_user_id: SUBJECT, body: "not mine", author: "UFF9")

    delete fd_member_note_path(SUBJECT, other_note)
    assert_not_nil other_note.reload.deleted_at
    assert_equal "Note removed", flash[:notice]

    delete fd_member_note_path(SUBJECT, own_note)
    assert_not_nil own_note.reload.deleted_at
  end

  test "member note update normalizes mentions and marks edited with an audit entry without text" do
    note = Fd::Note.create!(subject_user_id: SUBJECT, body: "spoke to tehm", author: "UFF9")

    patch fd_member_note_path(SUBJECT, note), params: { body: "spoke to them @U0ABCDEF12" }

    assert_redirected_to fd_member_path(SUBJECT)
    assert_equal "Note updated", flash[:notice]
    note.reload
    assert_equal "spoke to them <@U0ABCDEF12>", note.body
    assert_equal "UFF9", note.author
    assert note.edited?
    entry = Fd::AuditEntry.where(entity_type: "note", entity_id: note.id, verb: "edited").sole
    assert_no_match(/spoke to/, entry.to_json)
  end

  test "member note update with blank body redirects to the edit modal and keeps the body" do
    note = Fd::Note.create!(subject_user_id: SUBJECT, body: "keep", author: "UFF9")

    patch fd_member_note_path(SUBJECT, note), params: { body: " " }

    assert_redirected_to fd_member_path(SUBJECT, do: "edit-note-#{note.id}")
    assert_equal "Enter the note", flash[:field_error]["message"]
    assert_equal "keep", note.reload.body
  end

  test "member history shows edit and remove on standing notes by other authors" do
    note = Fd::Note.create!(subject_user_id: SUBJECT, body: "not mine", author: "UFF9")

    get fd_member_path(SUBJECT)

    assert_select "button[data-modal-open='edit-note-#{note.id}']", text: "Edit"
    assert_select "form[action='#{fd_member_note_path(SUBJECT, note)}'] button", text: "Remove"
    assert_select "[data-modal-id-value='edit-note-#{note.id}'] textarea[name='body']", text: "not mine"
  end

  test "member note update on another member is not found" do
    note = Fd::Note.create!(subject_user_id: "UOTHER99", body: "keep", author: "UFF9")

    patch fd_member_note_path(SUBJECT, note), params: { body: "changed" }

    assert_equal "Note not found", flash[:alert]
    assert_equal "keep", note.reload.body
  end
end
