require "test_helper"

class FdGatingTest < ActionDispatch::IntegrationTest
  setup do
    @me = Account.create!(user_id: "UFF1")
    hold_role!("UFF1", "firefighter")
    sign_in_as(@me)
  end

  def become(role)
    hold_role!("UFF1", role)
  end

  def dead(text)
    css_select(".btn-off, .text-btn.btn-off").find do |node|
      (node.at_css("span:not(.btn-why)") || node).text.strip == text
    end
  end

  test "a case somebody else is holding offers nothing but the reason why" do
    kase = make_case(assign: "UOTHER")

    get fd_case_path(kase)

    assert_response :success
    why = "case #{kase.id} is assigned to @UOTHER, not to you"
    assert_equal why, dead("Log an action")["title"]
    assert_equal why, dead("Log an action").at_css(".btn-why").text.strip,
      "a tooltip is no use on a keyboard, so the reason is in the row"

    get fd_case_path(kase, tab: "people")
    assert_select ".panel-head .btn-off", text: /Add somebody/
  end

  test "every item in the overflow menu can be reached by keyboard" do
    kase = make_case

    get fd_case_path(kase)

    assert_select ".ractions details.menu[data-controller=menu]", 1
    live = css_select(".ractions details.menu .menu-pop [data-modal-open]")
    assert live.any?, "the menu opens modals through buttons"
    live.each do |opener|
      assert_equal "button", opener.name,
        "#{opener.text.strip} must be a real button so Enter and Space open it"
    end
  end

  test "resolving is open to anyone, whoever is holding the case" do
    kase = make_case(assign: "UOTHER")

    get fd_case_path(kase)
    assert_nil dead("Resolve"), "somebody else holding it does not make it theirs to close"

    post fd_case_resolution_path(kase), params: { outcome: "close", close_reason: "no_action" }
    assert kase.reload.resolved?
  end

  test "the same buttons are live on a case of their own" do
    kase = make_case(assign: "UFF1")

    get fd_case_path(kase)

    assert_nil dead("Resolve")
    assert_nil dead("Log an action")
    assert_select "button[data-modal-open=?]", "resolve-case", text: "Resolve"
  end

  test "a resolved case anybody can reopen, whoever it was assigned to" do
    kase = make_case(assign: "UOTHER", resolved_at: 1.day.ago, resolution: "no_action")

    get fd_case_path(kase)
    assert_nil dead("Reopen"), "reopening is not scoped to the assignment"

    delete fd_case_resolution_path(kase)
    assert_not kase.reload.resolved?
  end

  test "an unclaimed case is free, so nothing is greyed" do
    get fd_case_path(make_case)

    assert_nil dead("Claim")
    assert_nil dead("Log an action")
  end

  test "filing a report on the way out needs the permission to log an action" do
    kase = make_case(assign: "UFF1")
    move_capability!("firefighter", "case.act", false, by: "UME")

    post fd_case_resolution_path(kase), params: { outcome: "report", type_key: "temp_ban",
      target_user_id: "USUB" }

    assert_equal 0, Fd::Action.where(case_id: kase.id).count
    assert_not kase.reload.resolved?

    post fd_case_resolution_path(kase), params: { outcome: "close", close_reason: "no_action" }
    assert kase.reload.resolved?, "resolving without an action is still theirs to do"
  end

  test "the palette says why a command is closed rather than hiding it" do
    kase = make_case(assign: "UOTHER")

    get fd_search_path(format: :json, q: ">", on_case: kase.id)

    rows = response.parsed_body["groups"].first["rows"]
    act = rows.find { |row| row["title"] == "Log an action" }
    assert_equal "case #{kase.id} is assigned to @UOTHER, not to you", act["why"]
    assert_nil rows.find { |row| row["title"] == "Resolve this case" }["why"]
    assert_nil rows.find { |row| row["title"] == "Go to the cases" }["why"]
  end

  test "the wording a greyed control shows is the wording the refusal uses" do
    kase = make_case(assign: "UOTHER")
    get fd_case_path(kase)
    shown = dead("Log an action")["title"]

    post fd_case_actions_path(kase), params: { kind: "warning", about: "USUB" }

    assert_equal shown, flash[:alert]
  end
end
