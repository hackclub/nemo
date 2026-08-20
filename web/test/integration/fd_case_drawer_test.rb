require "test_helper"

class FdCaseDrawerTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = make_case
    sign_in_as(@me)
  end

  def get_drawer(kase)
    get fd_case_path(kase), headers: { "Turbo-Frame" => "case-drawer" }
  end

  test "requesting a case from its own frame renders the drawer, not the full page" do
    get_drawer(@kase)

    assert_select "turbo-frame#case-drawer", 1
    assert_select ".drawer-h", 1
    assert_select ".card-title", 0, "the full case page's cards do not leak into the drawer"
  end

  test "a plain visit to the case still renders the whole page" do
    get fd_case_path(@kase)

    assert_select "turbo-frame#case-drawer", 0
    assert_select ".views .view", minimum: 1

    get fd_case_path(@kase, tab: "actions")
    assert_select ".card-note", text: "Nothing has been done yet."
  end

  test "the drawer offers to claim an unclaimed case" do
    get_drawer(@kase)

    assert_select "form[action=?] .keys-item", fd_case_claim_path(@kase)
  end

  test "the drawer offers to resolve a case that is already claimed" do
    @kase.assign!("UME")
    get_drawer(@kase)

    assert_select "a[href=?].keys-item", fd_case_path(@kase, do: "resolve")
    assert_select "form[action=?]", fd_case_claim_path(@kase), count: 0
  end

  test "a resolved case in the drawer offers neither claim nor resolve" do
    @kase.update!(resolved_at: Time.current, resolution: "no_action")
    get_drawer(@kase)

    assert_select ".keys-item", 0
  end

  test "the drawer shows the report that was filed" do
    Fd::CaseReport.create!(case_id: @kase.id, reporter_user_id: "UREP1", is_anonymous: false,
      body: "they keep DMing me", source_app: "shroud", received_at: Time.current)
    get_drawer(@kase)

    assert_select ".said-body", text: /they keep DMing me/
  end

  test "a resolved row greys out in place instead of disappearing" do
    @kase.update!(resolved_at: Time.current, resolution: "no_action")
    get fd_cases_path(view: "everything")

    assert_select "tr.row-resolved[data-row-link-href-value=?]", fd_case_path(@kase)
  end
end
