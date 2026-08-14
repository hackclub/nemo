require "test_helper"

class FdGatingTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UFF1", community_manager: false)
    Fd::AccessGrant.give!("UFF1", role: "firefighter", by: "UBOSS")
    sign_in_as(@me)
  end

  def become(role)
    Fd::AccessGrant.give!("UFF1", role: role, by: "UBOSS")
  end

  def dead(text)
    css_select(".btn-off, .text-btn.btn-off").find { |node| node.text.strip == text }
  end

  def proposal
    Fd::Decision.create!(title: "Pile-ons", statement: "one warning each",
      proposed_by: "UFF1", proposed_at: 2.days.ago)
  end

  test "a case somebody else is holding offers nothing but the reason why" do
    kase = make_case(assign: "UOTHER")

    get fd_case_path(kase)

    assert_response :success
    assert_equal "case #{kase.id} is assigned to @UOTHER, not to you",
      dead("Resolve")["title"]
    assert dead("Log an action"), "logging an action is theirs to do, not ours"
    assert_select ".index-add.btn-off", text: /Add somebody/
  end

  test "the same buttons are live on a case of their own" do
    kase = make_case(assign: "UFF1")

    get fd_case_path(kase)

    assert_nil dead("Resolve")
    assert_nil dead("Log an action")
    assert_select "label[for=?]", "resolve-case", text: "Resolve"
  end

  test "an unclaimed case is free, so nothing is greyed" do
    get fd_case_path(make_case)

    assert_nil dead("Claim")
    assert_nil dead("Log an action")
  end

  test "a firefighter is told settling is not theirs, and a lead is not" do
    decision = proposal

    get fd_decision_path(decision)
    assert_equal "settle a proposal, amend a settled one is lead only",
      dead("Settle it")["title"]

    become("lead")
    get fd_decision_path(decision)
    assert_nil dead("Settle it")
  end

  test "the greyed control is not a form that could still be posted" do
    get fd_decision_path(proposal)

    assert_select "form[action=?]", fd_decision_settlement_path(Fd::Decision.last), count: 0
  end

  test "the palette says why a command is closed rather than hiding it" do
    kase = make_case(assign: "UOTHER")

    get fd_search_path(format: :json, q: ">", on_case: kase.id)

    rows = response.parsed_body["groups"].first["rows"]
    resolve = rows.find { |row| row["title"] == "Resolve this case" }
    assert_equal "case #{kase.id} is assigned to @UOTHER, not to you", resolve["why"]
    assert_nil rows.find { |row| row["title"] == "Go to the cases" }["why"]
  end

  test "the wording a greyed control shows is the wording the refusal uses" do
    kase = make_case(assign: "UOTHER")
    get fd_case_path(kase)
    shown = dead("Resolve")["title"]

    post fd_case_resolution_path(kase), params: { resolution: "no_action" }

    assert_equal shown, flash[:alert]
  end
end
