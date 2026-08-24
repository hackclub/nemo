require "test_helper"

class DecisionsFlagTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
    Fd::Flag.delete_all
    Current.forget_flags
    @rule = Fd::Decision.create!(title: "No slurs", statement: "one warning each",
      proposed_by: @me.user_id)
  end

  teardown do
    Fd::Flag.delete_all
    Current.forget_flags
  end

  def turn_it_off
    Fd::Flag.set!(:decisions, false, by: @me.user_id)
  end

  test "with it on, the rail carries decisions and the section opens" do
    get fd_cases_path
    assert_select ".rail-text", text: "Decisions", count: 1

    get fd_decisions_path
    assert_response :success
  end

  test "with it off, the rail drops it and the rest of fire engine stays" do
    turn_it_off
    get fd_cases_path

    assert_select ".rail-text", text: "Decisions", count: 0
    assert_select ".rail-text", text: "Cases", count: 1
    assert_select ".rail-text", text: "Members", count: 1
  end

  test "with it off, the section and every page under it sends you to the queue" do
    turn_it_off

    get fd_decisions_path
    assert_redirected_to fd_cases_path
    assert_match(/decisions is turned off/, flash[:alert])

    get fd_decision_path(@rule)
    assert_redirected_to fd_cases_path
  end

  test "with it off, a case cannot be linked to one" do
    turn_it_off
    kase = make_case

    post fd_case_decision_path(kase), params: { decision_id: @rule.id }

    assert_redirected_to fd_cases_path
    assert_nil kase.reload.followed_decision_id
  end

  test "with it off, settling and retiring are refused too" do
    turn_it_off

    post fd_decision_settlement_path(@rule)
    assert_redirected_to fd_cases_path

    post fd_decision_retirement_path(@rule)
    assert_redirected_to fd_cases_path
  end

  test "with it off, the case page stops offering to link one" do
    kase = make_case

    get fd_case_path(kase)
    assert_select "label[for=follow-decision]", minimum: 1

    turn_it_off
    get fd_case_path(kase)
    assert_select "label[for=follow-decision]", count: 0
    assert_response :success
  end

  test "a case that already follows one keeps it, and still reads" do
    kase = make_case
    kase.update!(followed_decision_id: @rule.id)
    turn_it_off

    get fd_case_path(kase)

    assert_response :success
    assert_equal @rule.id, kase.reload.followed_decision_id, "flipping a switch deletes nothing"
  end
end
