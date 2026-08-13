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
    get fd_case_path(@kase)

    assert_select "button.handle[data-copy-id-value=USUB][title='copy USUB']"

    get fd_case_path(@kase, person: "UWATCHER")

    assert_select "#who .pane button.handle[data-copy-id-value=UWATCHER]"
  end

  test "one subject fills the pane, and the menu holds only them" do
    get fd_case_path(@kase)

    assert_select "#who a.index-item", 1
    assert_select "#who .pane .mcard-name button.handle", text: "@USUB"
  end

  test "everybody on the case is a row, and one of them is in the pane" do
    @kase.add_subject!("USECOND")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UWATCHER", role: "involved",
      detail: "they piled on")
    get fd_case_path(@kase)

    assert_select "#who a.index-item", 3
    assert_select "#who .pane .mcard-name", 1, "only one person is shown at a time"
    assert_select "#who a.index-item[aria-current=true]", 1
  end

  test "asking for somebody else puts them in the pane" do
    @kase.add_subject!("USECOND")
    get fd_case_path(@kase, person: "USECOND")

    assert_select "#who .pane .mcard-name button.handle", text: "@USECOND"
    assert_select "#who .pane .band-label", text: "Notes on @USECOND"
    assert_select "#who a.index-item[aria-current=true]", text: /@USECOND/
  end

  test "somebody who is not on the case cannot be asked for" do
    get fd_case_path(@kase, person: "UNOBODY")

    assert_response :success
    assert_select "#who .pane .mcard-name button.handle", text: "@USUB",
      count: 1, message: "an unknown id falls back to the first person"
  end

  test "one person holding two roles is one row, showing both" do
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "reporter")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "involved",
      detail: "they piled on")
    get fd_case_path(@kase, person: "UBOTH")

    assert_select "#who a.index-item", text: /@UBOTH/, count: 1
    assert_select "#who .pane .roles .line-row", 2
    assert_select "#who .pane .mcard-name .chip", text: "reported it"
    assert_select "#who .pane .roles .line-why b", text: "involved"
  end

  test "logging an action from a person's pane is aimed at that person" do
    @kase.add_subject!("USECOND")
    get fd_case_path(@kase, person: "USECOND")

    assert_select "input[name=target_user_id][value=USECOND]", minimum: 1
  end

  test "a case about nobody still renders, and says so once" do
    @kase.subjects.destroy_all
    get fd_case_path(@kase)

    assert_response :success
    assert_select "#who a.index-item", 0
    assert_select "#who .pane .card-note", text: "Nobody is logged on this case yet."
    assert_select ".subject-facts", 0, "there are no figures to show for nobody"
  end

  test "standing notes name the member they follow, once there is more than one" do
    @kase.add_subject!("USECOND")
    Fd::Note.create!(subject_user_id: "USECOND", body: "keeps at it", author: "UFF1")
    get fd_case_path(@kase)

    assert_select ".tl-head .chip", text: "about @USECOND"
  end
end
