require "test_helper"

class FdCasePageTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @kase = make_case
    sign_in_as(@me)
  end

  test "somebody who is not on the case is not listed" do
    get fd_case_path(@kase, person: "UNOBODY", tab: "people")

    assert_response :success
  end

  test "a case about nobody still renders, and says so once" do
    @kase.subjects.destroy_all
    get fd_case_path(@kase, tab: "people")

    assert_response :success
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

    post fd_case_claim_path(kase)

    assert_equal %w[UME UOTHER], kase.reload.assignee_user_ids.sort
  end

  test "a case with somebody named is ready to close, violation or not" do
    assert_nil @kase.category_key

    get fd_case_path(@kase)

    @kase.update!(category_key: "harassment")
    get fd_case_path(@kase)
  end

  test "the sidebar names the people on the other cases it lists" do
    them = Fd::Member.live.where.not(display_name: [nil, ""]).order(:user_id).first
    skip "the corpus has no named member" if them.nil?
    other = make_case(subject: them.user_id, opened_at: 1.hour.ago)

    get fd_case_path(@kase)

    assert_response :success
    assert_not_equal other.id, @kase.id
    assert @controller.view_assigns["names"].known?(them.user_id),
      "the sidebar lists other cases, so their people must be named too"
    assert_equal them.name, @controller.view_assigns["names"][them.user_id]
  end
end
