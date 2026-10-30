require "test_helper"

class FdNotesTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    @kase = make_case
  end

  def write(**params)
    post fd_case_notes_path(@kase), params: { body: "spoke to them in DM" }.merge(params)
  end

  def notes
    Fd::Note.where("case_id = ? OR subject_user_id = ?", @kase.id, @kase.subject_user_id)
  end

  def entries
    Fd::AuditEntry.where(entity_type: "note", entity_id: notes.ids.presence || [-1], verb: "noted")
  end

  test "create signed out redirects to login and writes no note" do
    write
    assert_redirected_to login_path
    assert_equal 0, notes.count
  end

  test "create stores a case note with author and body" do
    sign_in_as(@me)
    write(body: "they apologised, seemed genuine")

    note = notes.sole
    assert_equal @kase.id, note.case_id
    assert_nil note.subject_user_id
    assert_equal "they apologised, seemed genuine", note.body
    assert_equal "UME", note.author
    assert_not note.deleted?
  end

  test "create with about stores a standing note on the member without case_id" do
    sign_in_as(@me)
    write(about: "USUB", body: "escalates when corrected in public")

    note = notes.sole
    assert_nil note.case_id
    assert_equal "USUB", note.subject_user_id
    assert note.standing?
    assert_match(/Note added to @USUB/, flash[:notice])
  end

  test "create with about on a case without subjects is refused" do
    @kase.subjects.destroy_all
    sign_in_as(@me)
    write(about: "USUB")

    assert_equal 0, notes.count
    assert_empty Fd::Note.for_subject("USUB").to_a
    assert_match(/Not a subject of this case/, flash[:alert])
  end

  test "create with about for a non subject is refused and writes no note" do
    sign_in_as(@me)
    write(about: "UPASSERBY", body: "nothing to do with them")

    assert_empty Fd::Note.for_subject("UPASSERBY").to_a,
      "no note for a forged member id"
    assert_match(/Not a subject of this case/, flash[:alert])
  end

  test "create with about on a case with several subjects stores the note on that subject" do
    @kase.add_subject!("USECOND")
    sign_in_as(@me)
    write(about: "USECOND", body: "this one keeps at it")

    note = Fd::Note.for_subject("USECOND").sole
    assert_nil note.case_id
    assert_empty Fd::Note.for_subject("USUB").to_a, "no note for the other subject"
    assert_match(/Note added to @USECOND/, flash[:notice])
  end

  test "create with blank body is refused with a field error" do
    sign_in_as(@me)
    write(body: "   ")
    assert_equal 0, notes.count
    assert_nil flash[:alert], "a problem with one field is not a page-level message"
    assert_equal "body", flash[:field_error]["field"]
    assert_match(/Enter the note/i, flash[:field_error]["message"])
  end

  test "create strips whitespace from the body" do
    sign_in_as(@me)
    write(body: "  padded  ")
    assert_equal "padded", notes.sole.body
  end

  test "create with body over MAX_LENGTH is refused" do
    sign_in_as(@me)
    write(body: "x" * (Fd::NotesController::MAX_LENGTH + 1))
    assert_equal 0, notes.count
    assert_match(/Keep it under/, flash[:field_error]["message"])
    assert_nil flash[:field_error]["was"],
      "field_error omits was for a body over the limit"
  end

  test "create audit entry redacts the body to its length" do
    sign_in_as(@me)
    write(body: "he mentioned self harm")

    entry = entries.sole
    assert_equal "redacted, 22 chars", entry.after["body"]
    assert_no_match(/self harm/, entry.after.to_json)
    assert_equal "UME", entry.actor_user_id
  end

  test "destroy soft deletes the note and keeps the row" do
    sign_in_as(@me)
    write(body: "wrote this in haste")
    note = notes.sole

    delete fd_case_note_path(@kase, note)
    note.reload

    assert_not_nil note.deleted_at
    assert_equal "UME", note.deleted_by
    assert_equal "wrote this in haste", note.body, "body is kept after soft delete"
    assert_match(/Note removed/i, flash[:notice])
  end

  test "case note remove works on notes by other authors" do
    note = Fd::Note.create!(case_id: @kase.id, body: "not mine", author: "UFF9")
    sign_in_as(grant_role!("UFIRE", "firefighter"))
    delete fd_case_note_path(@kase, note)

    assert_equal "UFIRE", note.reload.deleted_by
    assert_equal "Note removed", flash[:notice]
  end

  test "case note update edits the body and keeps the author" do
    note = Fd::Note.create!(case_id: @kase.id, body: "spoke to tehm", author: "UFF9")
    sign_in_as(grant_role!("UFIRE", "firefighter"))
    patch fd_case_note_path(@kase, note), params: { body: "spoke to them" }

    assert_redirected_to fd_case_path(@kase, tab: "notes")
    assert_equal "Note updated", flash[:notice]
    note.reload
    assert_equal ["spoke to them", "UFF9", "UFIRE"], [note.body, note.author, note.edited_by]
    assert Fd::AuditEntry.exists?(entity_type: "note", entity_id: note.id, verb: "edited", actor_user_id: "UFIRE")
  end

  test "case note update without changes writes no audit entry" do
    note = Fd::Note.create!(case_id: @kase.id, body: "same", author: "UFF9")
    sign_in_as(@me)
    patch fd_case_note_path(@kase, note), params: { body: "same" }

    assert_equal "No changes", flash[:notice]
    assert_not note.reload.edited?
    assert_not Fd::AuditEntry.exists?(entity_type: "note", entity_id: note.id, verb: "edited")
  end

  test "case note update with blank body reopens the edit modal" do
    note = Fd::Note.create!(case_id: @kase.id, body: "keep", author: "UFF9")
    sign_in_as(@me)
    patch fd_case_note_path(@kase, note), params: { body: "" }

    assert_redirected_to fd_case_path(@kase, tab: "notes", do: "edit-note-#{note.id}")
    assert_equal "keep", note.reload.body
  end

  test "case note update on another case is not found" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    note = Fd::Note.create!(case_id: other.id, body: "keep", author: "UFF9")
    sign_in_as(@me)
    patch fd_case_note_path(@kase, note), params: { body: "changed" }

    assert_equal "Note not found", flash[:alert]
    assert_equal "keep", note.reload.body
  end

  test "case note update without case note capability is refused" do
    note = Fd::Note.create!(case_id: @kase.id, body: "keep", author: "UFF9")
    override_capability!("firefighter", "case.note", false)
    sign_in_as(grant_role!("UFIRE", "firefighter"))
    patch fd_case_note_path(@kase, note), params: { body: "changed" }

    assert_equal "keep", note.reload.body
  end

  test "case notes tab shows edit and remove for every note and the edited marker" do
    note = Fd::Note.create!(case_id: @kase.id, body: "by someone else <@U0ABCDEF12>", author: "UFF9")
    note.edit!("by someone else <@U0ABCDEF12>", by: "UFF9")
    sign_in_as(grant_role!("UFIRE", "firefighter"))
    get fd_case_path(@kase, tab: "notes")

    assert_select "button[data-modal-open='edit-note-#{note.id}']", text: "Edit"
    assert_select "form[action='#{fd_case_note_path(@kase, note)}'] button", text: "Remove"
    assert_select "[data-modal-id-value='edit-note-#{note.id}'] textarea[name='body']",
      text: "by someone else @U0ABCDEF12"
    assert_select ".lrow .sub", text: /edited/
  end

  test "destroy with a note from another case does not delete it" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    other_note = Fd::Note.create!(case_id: other.id, body: "somewhere else", author: "UME")

    sign_in_as(@me)
    delete fd_case_note_path(@kase, other_note)

    assert_nil other_note.reload.deleted_at, "the case in the url must own the note"
  end

  test "destroy twice writes one audit entry" do
    sign_in_as(@me)
    write(body: "twice over")
    note = notes.sole

    delete fd_case_note_path(@kase, note)
    first = note.reload.deleted_at
    delete fd_case_note_path(@kase, note)

    assert_equal first, note.reload.deleted_at
    assert_equal 1, Fd::AuditEntry.where(entity_type: "note", entity_id: note.id, verb: "deleted").count
  end

  test "destroy audit entry records deleted_by and redacts the body" do
    sign_in_as(@me)
    write(body: "he mentioned self harm")
    note = notes.sole
    delete fd_case_note_path(@kase, note)

    entry = Fd::AuditEntry.where(entity_type: "note", entity_id: note.id, verb: "deleted").sole
    assert_equal "UME", entry.after["deleted_by"]
    assert_equal "redacted, 22 chars", entry.after["body"]
    assert_no_match(/self harm/, entry.after.to_json)
  end

  test "destroy removes a standing note by its author" do
    sign_in_as(@me)
    write(about: "USUB", body: "pattern worth watching")
    note = notes.sole

    delete fd_case_note_path(@kase, note)
    assert_not_nil note.reload.deleted_at
  end

  test "create on a resolved case stores the note" do
    @kase.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    write(body: "adding this after the fact")
    assert_equal 1, notes.count
  end
end
