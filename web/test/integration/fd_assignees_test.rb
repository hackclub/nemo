require "test_helper"

class FdAssigneesTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @kase = make_case
  end

  def add(**params)
    post fd_case_assignees_path(@kase), params: { user_id: "UNEW" }.merge(params)
  end

  def held
    @kase.reload.assignee_user_ids
  end

  test "a signed out visitor cannot assign anybody" do
    add
    assert_redirected_to login_path
    assert_empty held
  end

  test "assigning somebody puts them on the case" do
    sign_in_as(@me)
    add

    assert_equal ["UNEW"], held
    assert_match(/@UNEW is now on the case/, flash[:notice])
  end

  test "assigning somebody else's case works too, case.open carries no scope" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    add

    assert_equal %w[UNEW UOTHER], held.sort
    assert_nil flash[:alert]
  end

  test "assigning the same person twice changes nothing" do
    sign_in_as(@me)
    add
    add

    assert_equal ["UNEW"], held
    assert_match(/already on this case, nothing changed/, flash[:notice])
  end

  test "several people are assigned in one go" do
    sign_in_as(@me)
    post fd_case_assignees_path(@kase), params: { user_ids: %w[UONE UTWO] }

    assert_equal %w[UONE UTWO], held.sort
    assert_match(/@UONE and @UTWO are now on the case/, flash[:notice])
  end

  test "a repeat among several does not stop the rest from landing" do
    sign_in_as(@me)
    add(user_id: "UONE")
    post fd_case_assignees_path(@kase), params: { user_ids: %w[UONE UTWO] }

    assert_equal %w[UONE UTWO], held.sort
    assert_match(/@UTWO is now on the case, 1 already there/, flash[:notice])
  end

  test "a handle typed with the at sign and in lower case still lands" do
    sign_in_as(@me)
    add(user_id: "  @unew  ")

    assert_equal ["UNEW"], held
  end

  test "a display name instead of a member id is refused" do
    sign_in_as(@me)
    add(user_id: "bob")

    assert_empty held
    assert_match(/does not look like a Slack member id/, flash[:alert])
  end

  test "a resolved case cannot be assigned to" do
    @kase.update!(resolved_at: Time.current, resolution: "no_action")
    sign_in_as(@me)
    add

    assert_empty held
    assert_match(/already resolved/, flash[:alert])
  end

  test "assigning writes a trail entry filed under the case" do
    sign_in_as(@me)
    add(user_id: "UNEW")

    entry = Fd::AuditEntry.where(entity_type: "assignee", entity_id: @kase.id,
      verb: "attached").sole
    assert_equal "UNEW", entry.after["user_id"]
    assert_equal "UME", entry.after["assigned_by"]
    assert_equal "UME", entry.actor_user_id
  end

  test "taking somebody off the case removes the row but not the record of it" do
    sign_in_as(@me)
    add(user_id: "UWRONG")
    delete fd_case_assignee_path(@kase, "UWRONG")

    assert_empty held
    entry = Fd::AuditEntry.where(entity_type: "assignee", entity_id: @kase.id,
      verb: "detached").sole
    assert_equal "UWRONG", entry.before["user_id"]
    assert_nil entry.after
  end

  test "removing somebody who is not on the case is refused" do
    sign_in_as(@me)
    delete fd_case_assignee_path(@kase, "USTRANGER")

    assert_match(/not on this case/, flash[:alert])
  end

  test "a member on another case cannot be removed through this one" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    other.assign!("UTHEIRS")

    sign_in_as(@me)
    delete fd_case_assignee_path(@kase, "UTHEIRS")

    assert_includes other.reload.assignee_user_ids, "UTHEIRS",
      "the case in the url must own the row"
  end

  test "removing works on a resolved case, only assigning is blocked" do
    @kase.assign!("UWRONG")
    @kase.update!(resolved_at: Time.current, resolution: "no_action")
    sign_in_as(@me)
    delete fd_case_assignee_path(@kase, "UWRONG")

    assert_empty held
  end
end
