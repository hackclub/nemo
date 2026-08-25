require "test_helper"

class FdCasePageTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = make_case
    sign_in_as(@me)
  end

  test "a name carries the id it copies, so a handle is never lost" do
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UWATCHER", role: "involved",
      detail: "they piled on")
    get fd_case_path(@kase, tab: "people")

    assert_select "button.handle[data-copy-id-value=USUB][title='copy USUB']"
    assert_select ".people-list button.handle[data-copy-id-value=UWATCHER]"
  end

  test "one subject is one row, carrying their name" do
    get fd_case_path(@kase, tab: "people")

    assert_select ".people-list .person-row", 1
    assert_select ".people-list .person-row button.handle", text: "@USUB"
  end

  test "everybody on the case is a row, and one of them is in the pane" do
    @kase.add_subject!("USECOND")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UWATCHER", role: "involved",
      detail: "they piled on")
    get fd_case_path(@kase, tab: "people")

    assert_select ".people-list .person-row", 3, "everybody is on the page at once"
    assert_select ".people-list .person-row a.btn", text: "History", count: 3
  end

  test "a second subject is a row of their own" do
    @kase.add_subject!("USECOND")
    get fd_case_path(@kase, tab: "people")

    assert_select ".people-list .person-row button.handle", text: "@USECOND"
    assert_select ".people-list .person-row", 2
  end

  test "somebody who is not on the case is not listed" do
    get fd_case_path(@kase, person: "UNOBODY", tab: "people")

    assert_response :success
    assert_select ".people-list .person-row", 1
    assert_select ".people-list .person-row button.handle", text: "@USUB"
  end

  test "one person holding two roles is one row, showing both" do
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "reporter")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "involved",
      detail: "they piled on")
    get fd_case_path(@kase, tab: "people")

    assert_select ".people-list .person-row", text: /@UBOTH/, count: 1
    assert_select ".people-list .people-role", text: "Involved"
    assert_select ".people-list .person-row", text: /also reported it/
  end

  test "each tab shows only its own section, not the others" do
    get fd_case_path(@kase, tab: "people")
    assert_select ".people-list .person-row", minimum: 1
    assert_select ".cols .empty-title", 0

    get fd_case_path(@kase, tab: "evidence")
    assert_select ".empty-title", text: "No evidence attached"
    assert_select ".people-list", 0

    get fd_case_path(@kase, tab: "actions")
    assert_select ".empty-title", text: "No action taken yet"
    assert_select ".people-list", 0

    get fd_case_path(@kase, tab: "notes")
    assert_select ".empty-title", text: "No notes yet"
    assert_select ".empty-title", text: "No action taken yet", count: 0
  end

  test "the report tab says so plainly when the case has no report on file" do
    get fd_case_path(@kase)

    assert_select ".card-note", text: /No report on file/
    assert_select ".card-note a.lnk", text: "@UFF1"
  end

  test "a duplicate names the case it was folded into, in the facts column" do
    other = make_case(subject: "UELSE", opened_at: 3.days.ago)
    @kase.update!(resolved_at: Time.current, resolution: "duplicate", duplicate_of: other.id)
    get fd_case_path(@kase)

    assert_select ".facts .fbox .ft", text: "Folded into"
    assert_select ".facts a[href=?]", fd_case_path(other), text: "case #{other.id}"
    assert_select "h2", text: "Duplicate Cases", count: 0
  end

  test "a name that leads to a member record is a link to it" do
    Fd::Note.create!(case_id: @kase.id, body: "spoke to them", author: "UFF1")
    get fd_case_path(@kase, tab: "notes")

    assert_select ".note-by a.lnk[href=?]", fd_member_path("UFF1"), text: "@UFF1"
  end

  test "the facts column names the people it mentions with links, not plain text" do
    @kase.assign!("UFF2")
    get fd_case_path(@kase)

    assert_select ".facts a[href=?]", fd_member_path(@kase.subject_user_ids.first)
  end

  test "logging an action from a person's pane is aimed at that person" do
    @kase.add_subject!("USECOND")
    get fd_case_path(@kase, person: "USECOND")

    assert_select "input[name=target_user_id][value=USECOND]", minimum: 1
  end

  test "a case about nobody still renders, and says so once" do
    @kase.subjects.destroy_all
    get fd_case_path(@kase, tab: "people")

    assert_response :success
    assert_select ".people-list .person-row", 0
    assert_select ".empty-title", text: "Nobody is on this case yet"
    assert_select ".empty-do .btn", text: "Say who it is about",
      count: 1, message: "adding somebody is still offered"
  end

  test "a standing note on a subject shows under them in the people tab" do
    @kase.add_subject!("USECOND")
    Fd::Note.create!(subject_user_id: "USECOND", body: "keeps at it", author: "UFF1")
    get fd_case_path(@kase, tab: "people")

    assert_select ".person-block .person-note .note-body", text: "keeps at it"
    assert_select ".person-note .sub2", text: /@UFF1/
  end

  test "setting the category writes it, and lands in the trail" do
    kase = make_case(category_key: nil)

    patch fd_case_path(kase), params: { category_key: "harassment_general" }

    assert_equal "harassment_general", kase.reload.category_key
    assert_equal 1, Fd::AuditEntry.where(entity_type: "case", entity_id: kase.id,
      verb: "categorised").count
  end

  test "a category that is already set is not overwritten" do
    kase = make_case(category_key: "spam")

    patch fd_case_path(kase), params: { category_key: "harassment_general" }

    assert_equal "spam", kase.reload.category_key
    assert_match(/already has a category/, flash[:alert])
  end

  test "a case somebody else holds still offers to put me on it too" do
    kase = make_case(assign: "UOTHER")

    get fd_case_path(kase)
    assert_select "form[action=?]", fd_case_claim_path(kase), minimum: 1

    post fd_case_claim_path(kase)

    assert_equal %w[UME UOTHER], kase.reload.assignee_user_ids.sort
  end

  test "the top bar carries the case number, not the violation" do
    @kase.update!(category_key: "harassment")
    get fd_case_path(@kase)

    assert_select ".head-title", text: @kase.id.to_s
    assert_select ".topbar .chip", 0, "no pills sit next to the case number"
  end

  test "the case names what it still needs instead of warning vaguely" do
    get fd_case_path(make_case(subject: nil))

    assert_select ".chip", { text: "nothing set yet", count: 0 },
      "a chip standing for one of three things told nobody which"
    assert_select ".todo .todo-t", text: "Three things before this can close"
    assert_select ".todo .todo-row .btn", 3
  end

  test "the count follows what is actually set" do
    get fd_case_path(@kase)
    assert_select ".todo .todo-t", text: "Two things before this can close"

    @kase.update!(category_key: "harassment")
    get fd_case_path(@kase)
    assert_select ".todo .todo-t", text: "One thing before this can close"
  end

  test "a case with nothing outstanding is not asked for anything" do
    @kase.update!(category_key: "harassment")
    Fd::CaseThread.create!(case_id: @kase.id, channel_id: "C1", thread_ts: "1700.1",
      added_by: "UME")
    get fd_case_path(@kase)

    assert_select ".card-asks", 0
  end

  test "an empty view keeps its place in the list" do
    get fd_case_path(@kase)

    views = css_select(".views .view").map { |view| view.text.split.first }
    assert_equal %w[Report Evidence Actions Notes People], views,
      "a view is hardest to find when you have not used it, so it must not move"
    assert_empty css_select(".views .views-fill"),
      "nothing is pushed to the far edge any more"
  end

  test "an empty view says nought rather than hiding" do
    get fd_case_path(@kase)

    notes = css_select(".views .view").find { |view| view.text.include?("Notes") }
    assert_equal "0", notes.css(".view-count").text
    assert_includes notes["class"], "view-off"
  end

  test "an empty tab offers the thing that fills it" do
    { "evidence" => "Attach a thread", "actions" => "Log an action",
      "notes" => "Add a note" }.each do |tab, offer|
      get fd_case_path(@kase, tab: tab)

      assert_select ".empty .empty-do", 1, "the #{tab} tab is a dead end without its control"
      assert_select ".empty .empty-do", text: /#{offer}/
    end
  end

  test "the notes header does not repeat the empty state's control" do
    get fd_case_path(@kase, tab: "notes")
    assert_select ".notes-head", 0, "one control, not two"

    Fd::Note.create!(case_id: @kase.id, author: "UME", body: "worth keeping")
    get fd_case_path(@kase, tab: "notes")
    assert_select ".notes-head", 1
  end

  test "a view with rows is not dimmed" do
    Fd::CaseChat.create!(case_id: @kase.id, author_user_id: "UME", body: "on it",
      source_app: "fire_engine")
    Fd::Note.create!(case_id: @kase.id, author: "UME", body: "worth keeping")
    get fd_case_path(@kase)

    notes = css_select(".views .view").find { |view| view.text.include?("Notes") }
    assert_equal "1", notes.css(".view-count").text
    assert_not_includes notes["class"].to_s, "view-off"
  end
end
