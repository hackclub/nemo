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

  test "a case somebody else is holding still offers everything to act on" do
    kase = make_case(assign: "UOTHER")

    get fd_case_path(kase)

    assert_response :success

    get fd_case_path(kase, tab: "people")
  end

  test "resolving is open to anyone, whoever is holding the case" do
    kase = make_case(assign: "UOTHER")

    get fd_case_path(kase)

    post fd_case_resolution_path(kase), params: { outcome: "close", close_reason: "no_action" }
    assert kase.reload.resolved?
  end

  test "a resolved case anybody can reopen, whoever it was assigned to" do
    kase = make_case(assign: "UOTHER", resolved_at: 1.day.ago, resolution: "no_action")

    get fd_case_path(kase)

    delete fd_case_resolution_path(kase)
    assert_not kase.reload.resolved?
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
    move_capability!("firefighter", "case.act", false, by: "UME")

    get fd_search_path(format: :json, q: ">", on_case: kase.id)

    rows = response.parsed_body["groups"].first["rows"]
    act = rows.find { |row| row["title"] == "Log an action" }
    assert_equal "log an action against somebody is Firefighter only", act["why"]
    assert_nil rows.find { |row| row["title"] == "Resolve this case" }["why"]
    assert_nil rows.find { |row| row["title"] == "Go to the cases" }["why"]
  end
end
