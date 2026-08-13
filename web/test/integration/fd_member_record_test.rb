require "test_helper"

class FdMemberRecordTest < ActionDispatch::IntegrationTest
  SUBJECT = "UPRIOR".freeze

  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def act_on(kase, target: SUBJECT, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: target,
                         decided_by: "UFF1", performed_by: "UFF1" }.merge(attrs))
  end

  test "a member with nothing on them still gets a page" do
    get fd_member_path("UNOBODY")

    assert_response :success
    assert_select ".chip", text: "nothing on record"
    assert_select ".card-note", text: /No conduct history/
    assert_select ".note-none", text: /Nothing written yet/
    assert_select ".spine", 0, "no shape to draw when there is no history"
  end

  test "the facts card is there even when the conduct half is empty" do
    get fd_member_path("UNOBODY")

    assert_select ".subject-facts .fact-label", text: "Messages"
    assert_select ".subject-facts .fact-label", text: "Priors, 12mo"
  end

  test "an open case shows as the badge, and links to it" do
    kase = make_case(subject: SUBJECT, opened_at: 2.days.ago)
    get fd_member_path(SUBJECT)

    assert_select "a.chip-crit[href=?]", fd_case_path(kase), text: "case ##{kase.id} open"
  end

  test "the shape counts what they were the subject of and what they were only logged in" do
    make_case(subject: SUBJECT, opened_at: 30.days.ago, resolved_at: 20.days.ago,
      resolution: "no_action")
    theirs = make_case(subject: "USOMEBODY", opened_at: 10.days.ago)
    theirs.participants.create!(user_id: SUBJECT, role: "involved", detail: "aimed at them")

    get fd_member_path(SUBJECT)

    assert_select ".shape-nums .fact-val", text: "1", minimum: 2
    assert_select ".spine-dot", 2
    assert_select ".spine-dot.dot-clear", 1
    assert_select ".spine-dot.dot-in", 1
  end

  test "a resolved case with an action reads differently from one without" do
    acted = make_case(subject: SUBJECT, opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "action_taken")
    act_on acted
    make_case(subject: SUBJECT, opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "no_action")

    get fd_member_path(SUBJECT)

    assert_select ".spine-dot.dot-done", 1
    assert_select ".spine-dot.dot-clear", 1
    assert_select ".spine-key", text: /action taken/
    assert_select ".spine-key", text: /resolved, no action/
  end

  test "the priors figure uses the definition, not the case count" do
    acted = make_case(subject: SUBJECT, opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "action_taken")
    act_on acted
    make_case(subject: SUBJECT, opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "no_action")
    make_case(subject: SUBJECT, opened_at: 2.days.ago)

    get fd_member_path(SUBJECT)

    assert_equal 1, Fd::Case.prior_count(SUBJECT, within: Fd::Case::PRIOR_WINDOW)
    assert_select ".fact-val", text: "1"
  end

  test "reversed actions are counted apart from the rest" do
    kase = make_case(subject: SUBJECT, opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "action_taken")
    act_on kase
    act_on kase, type_key: "shush", reversed_at: 20.days.ago, reversed_by: "UFF2",
      reversal_reason: "appeal upheld"

    get fd_member_path(SUBJECT)

    assert_select ".chip", text: /1 of 2 actions undone/
    assert_select ".shape-nums .muted", text: "1"
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

  test "the history lists every case and action, newest first" do
    old = make_case(subject: SUBJECT, opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "action_taken")
    act_on old, performed_at: 31.days.ago
    recent = make_case(subject: SUBJECT, opened_at: 2.days.ago)

    get fd_member_path(SUBJECT)

    assert_select ".card-title", text: "Their history"
    assert_select ".tl-item", 3
    assert_select ".tl-item:first-child a.tl-title", text: "Case #{recent.id} opened"
    assert_select "a.tl-title[href=?]", fd_case_path(old)
  end

  test "the history filter narrows without leaving the page" do
    kase = make_case(subject: SUBJECT, opened_at: 10.days.ago)
    act_on kase, performed_at: 3.days.ago

    get fd_member_path(SUBJECT, show: "actions")

    assert_select ".tl-item", 1
    assert_select ".segmented a[aria-current]", text: "Actions"
  end

  test "a filter that matches nothing says which nothing it is" do
    make_case(subject: SUBJECT, opened_at: 10.days.ago)
    get fd_member_path(SUBJECT, show: "actions")

    assert_select ".tl-item", 0
    assert_select ".card-note", text: /Nothing has ever been done to them/
  end

  test "a member with no history has no history card at all" do
    get fd_member_path("UNOBODY")
    assert_select ".card-title", text: "Their history", count: 0
  end

  test "the shape and the notes sit side by side, as drawn" do
    make_case(subject: SUBJECT, opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "no_action")
    get fd_member_path(SUBJECT)

    assert_select ".pair > .card", 2
    assert_select ".pair .spine"
    assert_select ".pair .card-title", text: /Notes on/
  end

  test "a note written here follows the member rather than a case" do
    get fd_member_path(SUBJECT)
    assert_select "form[action=?] textarea[name=body]", fd_member_notes_path(SUBJECT)

    post fd_member_notes_path(SUBJECT), params: { body: "escalates in public" }

    note = Fd::Note.for_subject(SUBJECT).sole
    assert_nil note.case_id, "a standing note belongs to the member, not a case"
    assert_equal "UME", note.author
    assert_match(/follows them to every case/, flash[:notice])
  end

  test "an empty note is refused here too" do
    post fd_member_notes_path(SUBJECT), params: { body: "   " }

    assert_empty Fd::Note.for_subject(SUBJECT).to_a
    assert_match(/write the note/, flash[:alert])
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

  test "a seeded member reads as their name with the id one click away" do
    seeded = Fd::Member.live.order(:user_id).first
    get fd_member_path(seeded.user_id)

    assert_select "button.handle[data-copy-id-value=?]", seeded.user_id
    assert_select ".card-title", text: seeded.name
  end
end
