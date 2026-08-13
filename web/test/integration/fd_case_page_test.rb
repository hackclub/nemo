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
    assert_select "#who-else button.handle[data-copy-id-value=UWATCHER]"
    assert_select "button.handle[data-controller=copy]", minimum: 2
  end

  test "one card for one subject" do
    get fd_case_path(@kase)

    assert_select ".subject .card-title", 1
    assert_select ".subject .card-title", text: "@USUB"
  end

  test "a case about several people gives each of them a card" do
    @kase.add_subject!("USECOND")
    get fd_case_path(@kase)

    assert_select ".subject .card-title", 2
    assert_select ".subject .card-title", text: "@USUB"
    assert_select ".subject .card-title", text: "@USECOND"
    assert_select ".subject-notes .fact-label", text: "Notes on @USECOND"
  end

  test "a case about nobody still renders, and says so once" do
    @kase.subjects.destroy_all
    get fd_case_path(@kase)

    assert_response :success
    assert_select ".subject .card-title", 1
    assert_select ".subject .card-title", text: "No subject set"
    assert_select ".subject-facts", 0, "there are no figures to show for nobody"
  end

  test "a subject is never listed as somebody else who was involved" do
    @kase.add_subject!("USECOND")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UWATCHER", role: "involved",
      detail: "they piled on")
    get fd_case_path(@kase)

    assert_select "#who-else .who-name", text: "@UWATCHER"
    assert_select "#who-else .who-name", text: "@USUB", count: 0
    assert_select "#who-else .who-name", text: "@USECOND", count: 0
  end

  test "with nobody else involved the list says so rather than naming the subject" do
    get fd_case_path(@kase)

    assert_select "#who-else .card-note", text: "n/a"
    assert_select "#who-else .who-row", 0
  end

  test "standing notes name the member they follow, once there is more than one" do
    @kase.add_subject!("USECOND")
    Fd::Note.create!(subject_user_id: "USECOND", body: "keeps at it", author: "UFF1")
    get fd_case_path(@kase)

    assert_select ".tl-head .chip", text: "about @USECOND"
  end
end
