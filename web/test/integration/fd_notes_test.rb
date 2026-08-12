require "test_helper"

class FdNotesTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = Fd::Case.create!(subject_user_id: "USUB", opened_by: "UFF1", opened_at: 2.days.ago)
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
    write(scope: "member", body: "escalates when corrected in public")

    note = notes.sole
    assert_nil note.case_id
    assert_equal "USUB", note.subject_user_id
    assert note.standing?
    assert_match(/noted against @USUB/, flash[:notice])
  end

  test "a standing note is refused when the case has no subject" do
    @kase.update!(subject_user_id: nil)
    sign_in_as(@me)
    write(scope: "member")

    assert_equal 0, notes.count
    assert_match(/nobody to note this against/, flash[:alert])
  end

  test "an empty note is refused rather than stored blank" do
    sign_in_as(@me)
    write(body: "   ")
    assert_equal 0, notes.count
    assert_match(/write the note/, flash[:alert])
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
    assert_match(/too long/, flash[:alert])
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
    assert_select ".tl-mark-note"
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
    assert_select "input[name=scope][value=case]"
    assert_select "input[name=scope][value=member]"
  end

  test "a case with no subject offers only the case scope" do
    @kase.update!(subject_user_id: nil)
    sign_in_as(@me)
    get fd_case_path(@kase)

    assert_select "input[name=scope][value=case]"
    assert_select "input[name=scope][value=member]", count: 0
  end
end
