require "test_helper"

class FdNotesTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
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

  test "a signed out visitor cannot write a note" do
    write
    assert_redirected_to login_path
    assert_equal 0, notes.count
  end

  test "a note on the case records who wrote it and when" do
    sign_in_as(@me)
    write(body: "they apologised, seemed genuine")

    note = notes.sole
    assert_equal @kase.id, note.case_id
    assert_nil note.subject_user_id
    assert_equal "they apologised, seemed genuine", note.body
    assert_equal "UME", note.author
    assert_not note.deleted?
  end

  test "a standing note attaches to the member, not the case" do
    sign_in_as(@me)
    write(about: "USUB", body: "escalates when corrected in public")

    note = notes.sole
    assert_nil note.case_id
    assert_equal "USUB", note.subject_user_id
    assert note.standing?
    assert_match(/noted against @USUB/, flash[:notice])
  end

  test "a standing note is refused when the case has no subject" do
    @kase.subjects.destroy_all
    sign_in_as(@me)
    write(about: "USUB")

    assert_equal 0, notes.count
    assert_empty Fd::Note.for_subject("USUB").to_a
    assert_match(/not a subject of this case/, flash[:alert])
  end

  test "a standing note cannot be filed against somebody who is not a subject" do
    sign_in_as(@me)
    write(about: "UPASSERBY", body: "nothing to do with them")

    assert_empty Fd::Note.for_subject("UPASSERBY").to_a,
      "a forged member id must write nothing at all"
    assert_match(/not a subject of this case/, flash[:alert])
  end

  test "with several subjects the note lands on the one that was chosen" do
    @kase.add_subject!("USECOND")
    sign_in_as(@me)
    write(about: "USECOND", body: "this one keeps at it")

    note = Fd::Note.for_subject("USECOND").sole
    assert_nil note.case_id
    assert_empty Fd::Note.for_subject("USUB").to_a, "the other subject keeps a clean record"
    assert_match(/noted against @USECOND/, flash[:notice])
  end

  test "an empty note is refused rather than stored blank" do
    sign_in_as(@me)
    write(body: "   ")
    assert_equal 0, notes.count
    assert_nil flash[:alert], "a problem with one field is not a page-level message"
    assert_equal "body", flash[:wrong]["field"]
    assert_match(/Write the note/i, flash[:wrong]["said"])
  end

  test "the body is trimmed before it is stored" do
    sign_in_as(@me)
    write(body: "  padded  ")
    assert_equal "padded", notes.sole.body
  end

  test "an absurdly long note is refused" do
    sign_in_as(@me)
    write(body: "x" * (Fd::NotesController::MAX_LENGTH + 1))
    assert_equal 0, notes.count
    assert_match(/Keep it under/, flash[:wrong]["said"])
    assert_nil flash[:wrong]["was"],
      "a body over the limit will not fit in a cookie, so it is not carried back"
  end

  test "the note text never reaches the trail, only its length" do
    sign_in_as(@me)
    write(body: "he mentioned self harm")

    entry = entries.sole
    assert_equal "redacted, 22 chars", entry.after["body"]
    assert_no_match(/self harm/, entry.after.to_json)
    assert_equal "UME", entry.actor_user_id
  end

  test "markup in a note is escaped, not rendered" do
    sign_in_as(@me)
    write(body: "<script>alert(1)</script>")

    get fd_case_path(@kase)
    assert_no_match(%r{<script>alert\(1\)</script>}, response.body)
    assert_match(/&lt;script&gt;/, response.body)
  end

  test "a note shows up in the timeline it was written into" do
    sign_in_as(@me)
    write(body: "asked a second firefighter to read this")

    get fd_case_path(@kase)
    assert_match(/asked a second firefighter to read this/, response.body)
    assert_select ".tl-item.tl-note"
  end

  test "anybody opening the case sees the notes without hunting for them" do
    Fd::Note.create!(case_id: @kase.id, body: "spoke to them in DM", author: "UFF1")
    Fd::Note.create!(subject_user_id: "USUB", body: "escalates in public", author: "UFF2")

    sign_in_as(Staff.create!(user_id: "UOTHER", community_manager: true))
    get fd_case_path(@kase, tab: "notes")

    assert_select ".note-row", 1
    assert_select ".note-body", text: "spoke to them in DM"
    assert_select ".note-by", text: /@UFF1/

    get fd_case_path(@kase, tab: "people")
    assert_select ".person-note .note-body", { text: "escalates in public" },
      "a standing note follows the member onto any case that names them"
    assert_select ".notes .note-row", { count: 0 },
      "but it is not a note on this case, so it stays off the notes tab"

    get fd_member_path("USUB", show: "notes")
    assert_select ".record-table", text: /escalates in public/
  end

  test "a standing note is marked as being about the member, not the case" do
    Fd::Note.create!(subject_user_id: "USUB", body: "watch for repeats", author: "UFF2")
    sign_in_as(@me)
    get fd_member_path("USUB", show: "notes")

    assert_select ".record-table", text: /watch for repeats/
  end

  test "a standing note shows for somebody who is not a subject" do
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UWATCHER", role: "involved",
      detail: "they piled on")
    Fd::Note.create!(subject_user_id: "UWATCHER", body: "keeps turning up", author: "UFF2")
    sign_in_as(@me)
    get fd_member_path("UWATCHER", show: "notes")

    assert_select ".record-table", text: /keeps turning up/
  end

  test "a deleted note is not shown on the page" do
    Fd::Note.create!(case_id: @kase.id, body: "struck from the record", author: "UFF1",
      deleted_at: Time.current, deleted_by: "UFF1")
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "notes")

    assert_select ".note-row", 0
    assert_no_match(/struck from the record/, response.body)
  end

  test "the notes card says so when there is nothing written" do
    sign_in_as(@me)
    get fd_case_path(@kase, tab: "notes")
    assert_select ".empty-title", text: "No notes yet"
    assert_select ".empty .empty-do", text: /Add a note/
  end

  test "removing my own note leaves it soft deleted, not gone" do
    sign_in_as(@me)
    write(body: "wrote this in haste")
    note = notes.sole

    delete fd_case_note_path(@kase, note)
    note.reload

    assert_not_nil note.deleted_at
    assert_equal "UME", note.deleted_by
    assert_equal "wrote this in haste", note.body, "the row stays, only the visibility changes"
    assert_match(/Note removed/i, flash[:notice])
    assert_match(/stays in the audit trail/, flash[:said])
  end

  test "a removed note leaves a mark in the timeline" do
    sign_in_as(@me)
    write(body: "wrote this in haste")
    delete fd_case_note_path(@kase, notes.sole)

    get fd_case_path(@kase)
    assert_select ".tl-title", text: "Note removed"
    assert_select ".tl-detail", text: /@UME/
    assert_no_match(/wrote this in haste/, response.body)
  end

  test "a removed note disappears from the page" do
    sign_in_as(@me)
    write(body: "wrote this in haste")
    delete fd_case_note_path(@kase, notes.sole)

    get fd_case_path(@kase)
    assert_select ".note-row", 0
    assert_no_match(/wrote this in haste/, response.body)
  end

  test "I cannot remove somebody else's note" do
    note = Fd::Note.create!(case_id: @kase.id, body: "not mine", author: "UFF9")
    sign_in_as(@me)
    delete fd_case_note_path(@kase, note)

    assert_nil note.reload.deleted_at
    assert_match(/only whoever wrote a note can remove it/, flash[:alert])
  end

  test "a note belonging to another case cannot be removed through this one" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    theirs = Fd::Note.create!(case_id: other.id, body: "somewhere else", author: "UME")

    sign_in_as(@me)
    delete fd_case_note_path(@kase, theirs)

    assert_nil theirs.reload.deleted_at, "the case in the url must own the note"
  end

  test "removing twice does not write a second trail entry" do
    sign_in_as(@me)
    write(body: "twice over")
    note = notes.sole

    delete fd_case_note_path(@kase, note)
    first = note.reload.deleted_at
    delete fd_case_note_path(@kase, note)

    assert_equal first, note.reload.deleted_at
    assert_equal 1, Fd::AuditEntry.where(entity_type: "note", entity_id: note.id, verb: "deleted").count
  end

  test "the trail records that a note was struck without keeping what it said" do
    sign_in_as(@me)
    write(body: "he mentioned self harm")
    note = notes.sole
    delete fd_case_note_path(@kase, note)

    entry = Fd::AuditEntry.where(entity_type: "note", entity_id: note.id, verb: "deleted").sole
    assert_equal "UME", entry.after["deleted_by"]
    assert_equal "redacted, 22 chars", entry.after["body"]
    assert_no_match(/self harm/, entry.after.to_json)
  end

  test "a standing note can be removed by its author from the case page" do
    sign_in_as(@me)
    write(about: "USUB", body: "pattern worth watching")
    note = notes.sole

    delete fd_case_note_path(@kase, note)
    assert_not_nil note.reload.deleted_at
  end

  test "only my own notes offer a remove control" do
    Fd::Note.create!(case_id: @kase.id, body: "mine", author: "UME")
    Fd::Note.create!(case_id: @kase.id, body: "theirs", author: "UFF9")

    sign_in_as(@me)
    get fd_case_path(@kase, tab: "notes")
    assert_select ".note-by .text-btn", 1
  end

  test "notes can still be written on a resolved case" do
    @kase.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    sign_in_as(@me)
    write(body: "adding this after the fact")
    assert_equal 1, notes.count
  end

  test "the case page offers the note modal with both scopes" do
    sign_in_as(@me)
    get fd_case_path(@kase)

    assert_select "input#add-note.modal-flip"
    assert_select "form[action=?] textarea[name=body]", fd_case_notes_path(@kase)
    assert_select "input[name=about][value=case][checked]"
    assert_select "input[name=about][value=USUB]"
  end

  test "a case with no subject offers only the case scope" do
    @kase.subjects.destroy_all
    sign_in_as(@me)
    get fd_case_path(@kase)

    assert_select "input[name=about][value=case]"
    assert_select "input[name=about]", count: 1
  end

  test "every subject is offered by name, so the note says who it is about" do
    @kase.add_subject!("USECOND")
    sign_in_as(@me)
    get fd_case_path(@kase)

    assert_select "input[name=about][value=USUB]"
    assert_select "input[name=about][value=USECOND]"
    assert_select ".opt-label", text: "About @USECOND"
  end
end
