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

    get fd_case_path(@kase, person: "UWATCHER", tab: "people")

    assert_select "#who .pane button.handle[data-copy-id-value=UWATCHER]"
  end

  test "one subject fills the pane, and the menu holds only them" do
    get fd_case_path(@kase, tab: "people")

    assert_select "#who a.index-item", 1
    assert_select "#who .pane .mcard-name button.handle", text: "@USUB"
  end

  test "everybody on the case is a row, and one of them is in the pane" do
    @kase.add_subject!("USECOND")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UWATCHER", role: "involved",
      detail: "they piled on")
    get fd_case_path(@kase, tab: "people")

    assert_select "#who a.index-item", 3
    assert_select "#who .pane .mcard-name", 1, "only one person is shown at a time"
    assert_select "#who a.index-item[aria-current=true]", 1
  end

  test "asking for somebody else puts them in the pane" do
    @kase.add_subject!("USECOND")
    get fd_case_path(@kase, person: "USECOND", tab: "people")

    assert_select "#who .pane .mcard-name button.handle", text: "@USECOND"
    assert_select "#who .pane .band-label", text: "Notes on @USECOND"
    assert_select "#who a.index-item[aria-current=true]", text: /@USECOND/
  end

  test "somebody who is not on the case cannot be asked for" do
    get fd_case_path(@kase, person: "UNOBODY", tab: "people")

    assert_response :success
    assert_select "#who .pane .mcard-name button.handle", text: "@USUB",
      count: 1, message: "an unknown id falls back to the first person"
  end

  test "one person holding two roles is one row, showing both" do
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "reporter")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "involved",
      detail: "they piled on")
    get fd_case_path(@kase, person: "UBOTH", tab: "people")

    assert_select "#who a.index-item", text: /@UBOTH/, count: 1
    assert_select "#who .pane .roles .line-row", 2
    assert_select "#who .pane .mcard-name .chip", text: "reported it"
    assert_select "#who .pane .roles .line-why b", text: "involved"
  end

  test "each tab shows only its own section, not the others" do
    get fd_case_path(@kase, tab: "people")
    assert_match(/Who is on this case/, response.body)
    assert_select ".card-title", text: "What was done", count: 0

    get fd_case_path(@kase, tab: "evidence")
    assert_match(/The evidence/, response.body)
    assert_no_match(/Who is on this case/, response.body)

    get fd_case_path(@kase, tab: "actions")
    assert_select ".card-title", text: "What was done"
    assert_no_match(/The threads/, response.body)

    get fd_case_path(@kase, tab: "notes")
    assert_select ".card-title", text: "Notes"
    assert_select ".card-title", text: "What was done", count: 0
  end

  test "the report tab says so plainly when the case has no report on file" do
    get fd_case_path(@kase)

    assert_select ".card-note", text: /No report on file/
    assert_select ".card-note a.lnk", text: "@UFF1"
  end

  test "a duplicate is a chip in the header, not a card of its own" do
    other = make_case(subject: "UELSE", opened_at: 3.days.ago)
    @kase.update!(resolved_at: Time.current, resolution: "duplicate", duplicate_of: other.id)
    get fd_case_path(@kase)

    assert_select ".chip[href=?]", fd_case_path(other), text: "duplicate of case #{other.id}"
    assert_select "h2", text: "Duplicate Cases", count: 0
  end

  test "a name that leads to a member record is a link to it" do
    Fd::Note.create!(case_id: @kase.id, body: "spoke to them", author: "UFF1")
    get fd_case_path(@kase, tab: "notes")

    assert_select ".note-by a.lnk[href=?]", fd_member_path("UFF1"), text: "@UFF1"
  end

  test "the header names the people it mentions with links, not plain text" do
    @kase.assign!("UFF2")
    get fd_case_path(@kase)

    assert_select ".head-meta a.lnk[href=?]", fd_member_path("UFF2")
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
    assert_select "#who a.index-item", 0
    assert_select "#who .pane .card-note", text: "Nobody logged yet."
    assert_select ".subject-facts", 0, "there are no figures to show for nobody"
  end

  test "standing notes name the member they follow, once there is more than one" do
    @kase.add_subject!("USECOND")
    Fd::Note.create!(subject_user_id: "USECOND", body: "keeps at it", author: "UFF1")
    get fd_case_path(@kase)

    assert_select ".tl-head .chip", text: "about @USECOND"
  end
end
