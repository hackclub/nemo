require "test_helper"

class FdCasePageTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    @kase = make_case
    sign_in_as(@me)
  end

  test "people tab with a person param not on the case returns success" do
    get fd_case_path(@kase, person: "UNOBODY", tab: "people")

    assert_response :success
  end

  test "case page resolved in past year shows year on closed line" do
    resolved = Time.zone.local(Date.current.year - 1, 3, 3, 12)
    kase = make_case(opened_at: resolved - 2.days, resolved_at: resolved, resolution: "no_action")

    get fd_case_path(kase)

    assert_select ".closed-what", /Closed 3 Mar #{resolved.year}/
  end

  test "people tab with no subjects returns success" do
    @kase.subjects.destroy_all
    get fd_case_path(@kase, tab: "people")

    assert_response :success
  end

  test "update with category_key saves it and audits categorised" do
    kase = make_case(category_key: nil)

    patch fd_case_path(kase), params: { category_key: "harassment_general" }

    assert_equal "harassment_general", kase.reload.category_key
    assert_equal 1, Fd::AuditEntry.where(entity_type: "case", entity_id: kase.id,
      verb: "categorised").count
  end

  test "update with category_key replaces an existing category and audits the change" do
    kase = make_case(category_key: "spam")

    patch fd_case_path(kase), params: { category_key: "harassment_general" }

    assert_equal "harassment_general", kase.reload.category_key
    entry = Fd::AuditEntry.where(entity_type: "case", entity_id: kase.id, verb: "categorised").first
    assert_equal({ "category_key" => "spam" }, entry.before)
    assert_equal({ "category_key" => "harassment_general" }, entry.after)
  end

  test "update with the current category_key writes nothing" do
    kase = make_case(category_key: "spam")

    patch fd_case_path(kase), params: { category_key: "spam" }

    assert_redirected_to fd_case_path(kase)
    assert_equal 0, Fd::AuditEntry.where(entity_type: "case", entity_id: kase.id, verb: "categorised").count
  end

  test "claim on a case assigned to another user adds me to the assignees" do
    kase = make_case(assign: "UOTHER")

    get fd_case_path(kase)

    post fd_case_claim_path(kase)

    assert_equal %w[UME UOTHER], kase.reload.assignee_user_ids.sort
  end

  test "case page renders before and after a category is set" do
    assert_nil @kase.category_key

    get fd_case_path(@kase)

    @kase.update!(category_key: "harassment")
    get fd_case_path(@kase)
  end

  test "sidebar resolves names for subjects of other cases" do
    named_member = Fd::Member.live.where.not(display_name: [nil, ""]).order(:user_id).first
    skip "the corpus has no named member" if named_member.nil?
    other = make_case(subject: named_member.user_id, opened_at: 1.hour.ago)

    get fd_case_path(@kase)

    assert_response :success
    assert_not_equal other.id, @kase.id
    assert @controller.view_assigns["names"].known?(named_member.user_id),
      "names include the subject of the other case"
    assert_equal named_member.name, @controller.view_assigns["names"][named_member.user_id]
  end

  test "unassign menu item shows the assignee display name" do
    named_member = Fd::Member.live.where.not(display_name: [nil, ""]).order(:user_id).first
    skip "the corpus has no named member" if named_member.nil?
    kase = make_case(assign: named_member.user_id)

    get fd_case_path(kase)

    assert_select ".menu-item-title", text: "Unassign #{named_member.name}"
    assert_select ".menu-item-title", text: "Unassign @#{named_member.user_id}", count: 0
  end
end
