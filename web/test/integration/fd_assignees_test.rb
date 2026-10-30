require "test_helper"

class FdAssigneesTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    @kase = make_case
  end

  def add(**params)
    post fd_case_assignees_path(@kase), params: { user_id: "UNEW" }.merge(params)
  end

  def assignee_ids
    @kase.reload.assignee_user_ids
  end

  test "assignees create signed out redirects to login and adds nothing" do
    add
    assert_redirected_to login_path
    assert_empty assignee_ids
  end

  test "assignees create adds user to case and sets notice" do
    sign_in_as(@me)
    add

    assert_equal ["UNEW"], assignee_ids
    assert_match(/@UNEW assigned/, flash[:notice])
  end

  test "assignees create on case with another assignee adds second assignee" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    add

    assert_equal %w[UNEW UOTHER], assignee_ids.sort
    assert_nil flash[:alert]
  end

  test "assignees create twice with same user keeps one assignee" do
    sign_in_as(@me)
    add
    add

    assert_equal ["UNEW"], assignee_ids
    assert_match(/Already assigned/, flash[:notice])
  end

  test "assignees create with user_ids adds every user" do
    sign_in_as(@me)
    post fd_case_assignees_path(@kase), params: { user_ids: %w[UONE UTWO] }

    assert_equal %w[UONE UTWO], assignee_ids.sort
    assert_match(/@UONE and @UTWO assigned/, flash[:notice])
  end

  test "assignees create with user_ids including existing assignee adds the others" do
    sign_in_as(@me)
    add(user_id: "UONE")
    post fd_case_assignees_path(@kase), params: { user_ids: %w[UONE UTWO] }

    assert_equal %w[UONE UTWO], assignee_ids.sort
    assert_match(/@UTWO assigned · 1 already assigned/, flash[:notice])
  end

  test "assignees create normalizes at sign and lower case in user_id" do
    sign_in_as(@me)
    add(user_id: "  @unew  ")

    assert_equal ["UNEW"], assignee_ids
  end

  test "assignees create with non member id sets alert and adds nothing" do
    sign_in_as(@me)
    add(user_id: "bob")

    assert_empty assignee_ids
    assert_match(/Not a Slack member ID/, flash[:alert])
  end

  test "assignees create on resolved case sets alert and adds nothing" do
    @kase.update!(resolved_at: Time.current, resolution: "no_action")
    sign_in_as(@me)
    add

    assert_empty assignee_ids
    assert_match(/already resolved/, flash[:alert])
  end

  test "assignees create records attached audit entry for the case" do
    sign_in_as(@me)
    add(user_id: "UNEW")

    entry = Fd::AuditEntry.where(entity_type: "assignee", entity_id: @kase.id,
      verb: "attached").sole
    assert_equal "UNEW", entry.after["user_id"]
    assert_equal "UME", entry.after["assigned_by"]
    assert_equal "UME", entry.actor_user_id
  end

  test "assignees destroy removes assignee and records detached audit entry" do
    sign_in_as(@me)
    add(user_id: "UWRONG")
    delete fd_case_assignee_path(@kase, "UWRONG")

    assert_empty assignee_ids
    entry = Fd::AuditEntry.where(entity_type: "assignee", entity_id: @kase.id,
      verb: "detached").sole
    assert_equal "UWRONG", entry.before["user_id"]
    assert_nil entry.after
  end

  test "assignees destroy with unassigned user sets Not assigned alert" do
    sign_in_as(@me)
    delete fd_case_assignee_path(@kase, "USTRANGER")

    assert_match(/Not assigned/, flash[:alert])
  end

  test "assignees destroy with user assigned to another case keeps that assignee" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    other.assign!("UTHEIRS")

    sign_in_as(@me)
    delete fd_case_assignee_path(@kase, "UTHEIRS")

    assert_includes other.reload.assignee_user_ids, "UTHEIRS",
      "assignee row belongs to the case in the url"
  end

  test "assignees destroy on resolved case removes assignee" do
    @kase.assign!("UWRONG")
    @kase.update!(resolved_at: Time.current, resolution: "no_action")
    sign_in_as(@me)
    delete fd_case_assignee_path(@kase, "UWRONG")

    assert_empty assignee_ids
  end
end
