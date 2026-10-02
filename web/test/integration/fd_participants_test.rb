require "test_helper"

class FdParticipantsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @kase = make_case
  end

  def add(**params)
    post fd_case_participants_path(@kase),
      params: { user_id: "UNEW" }.merge(params)
  end

  def people
    Fd::CaseParticipant.where(case_id: @kase.id).where.not(user_id: "USUB")
  end

  test "a signed out visitor cannot add anybody" do
    add
    assert_redirected_to login_path
    assert_empty people.to_a
  end

  test "anybody added by hand is a subject" do
    sign_in_as(@me)
    add(user_id: "UNEW")

    assert_equal "subject", people.sole.role
    assert_match(/the case is now also about @UNEW/, flash[:notice])
  end

  test "a role asked for by hand is ignored, the menu only adds subjects" do
    sign_in_as(@me)
    add(user_id: "UTOLDUS", role: "reporter")

    assert_equal "subject", people.sole.role,
      "several reporters only come from a merge, never from this menu"
  end

  test "a second subject makes the case about both of them" do
    sign_in_as(@me)
    add(user_id: "USECOND")

    assert_equal %w[USECOND USUB], @kase.reload.subject_user_ids
    assert_match(/the case is now also about @USECOND/, flash[:notice])
  end

  test "a handle typed with the at sign and in lower case still lands" do
    sign_in_as(@me)
    add(user_id: "  @unew  ")

    assert_equal "UNEW", people.sole.user_id
  end

  test "a display name instead of a member id is refused" do
    sign_in_as(@me)
    add(user_id: "bob")

    assert_empty people.to_a
    assert_match(/does not look like a Slack member id/, flash[:alert])
  end

  test "a role asked for outside the menu is ignored, not obeyed" do
    sign_in_as(@me)
    add(role: "witness")

    assert_equal "subject", people.sole.role
    assert_nil flash[:alert]
  end

  test "adding the same person in the same role twice changes nothing" do
    sign_in_as(@me)
    add
    add

    assert_equal 1, people.count
    assert_nil flash[:alert], "a repeat is a no-op, not something to warn about"
    assert_match(/already on this case, nothing changed/, flash[:notice])
  end

  test "several subjects are added in one go" do
    sign_in_as(@me)
    post fd_case_participants_path(@kase),
      params: { user_ids: %w[UONE UTWO UTHREE], role: "subject" }

    assert_equal %w[UONE UTHREE UTWO], people.map(&:user_id).sort
    assert_match(/the case is now also about @UONE, @UTWO, and @UTHREE/, flash[:notice])
  end

  test "a repeat among several does not stop the rest from landing" do
    sign_in_as(@me)
    add(user_id: "UONE")
    post fd_case_participants_path(@kase),
      params: { user_ids: %w[UONE UTWO], role: "subject" }

    assert_equal %w[UONE UTWO], people.map(&:user_id).sort,
      "the duplicate must not abort the transaction the others are riding in"
    assert_match(/the case is now also about @UTWO, 1 already there/, flash[:notice])
  end

  test "one bad id in a batch refuses the whole batch" do
    sign_in_as(@me)
    post fd_case_participants_path(@kase),
      params: { user_ids: %w[UONE bob], role: "subject" }

    assert_empty people.to_a
    assert_match(/does not look like a Slack member id/, flash[:alert])
  end

  test "one person can hold two roles on one case" do
    sign_in_as(@me)
    add(user_id: "UBOTH")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "reporter")

    assert_equal %w[reporter subject], people.map(&:role).sort
  end

  test "a case assigned to somebody else can still be added to" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    add

    assert_equal 1, people.count
    assert_match(/the case is now also about @UNEW/, flash[:notice])
  end

  test "adding writes a trail entry filed under the case" do
    sign_in_as(@me)
    add(user_id: "UNEW")

    entry = Fd::AuditEntry.where(entity_type: "participant", entity_id: @kase.id,
      verb: "attached").sole
    assert_equal "UNEW", entry.after["user_id"]
    assert_equal "subject", entry.after["role"]
    assert_equal "UME", entry.actor_user_id
  end

  test "taking somebody off the case removes the row but not the record of it" do
    sign_in_as(@me)
    add(user_id: "UWRONG")
    delete fd_case_participant_path(@kase, "UWRONG"), params: { role: "subject" }

    assert_empty people.to_a
    entry = Fd::AuditEntry.where(entity_type: "participant", entity_id: @kase.id,
      verb: "detached").sole
    assert_equal "UWRONG", entry.before["user_id"]
    assert_nil entry.after
  end

  test "removing names the role, so the other one stays" do
    sign_in_as(@me)
    add(user_id: "UBOTH")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "reporter")

    delete fd_case_participant_path(@kase, "UBOTH"), params: { role: "reporter" }

    assert_equal ["subject"], people.map(&:role)
  end

  test "a mistaken subject can be taken back off" do
    sign_in_as(@me)
    add(user_id: "UINNOCENT", role: "subject")
    delete fd_case_participant_path(@kase, "UINNOCENT"), params: { role: "subject" }

    assert_equal ["USUB"], @kase.reload.subject_user_ids
  end

  test "somebody who is not on the case cannot be removed from it" do
    sign_in_as(@me)
    delete fd_case_participant_path(@kase, "USTRANGER"), params: { role: "subject" }
    assert_match(/not on this case/, flash[:alert])
  end

  test "a member on another case cannot be removed through this one" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    Fd::CaseParticipant.create!(case_id: other.id, user_id: "UTHEIRS", role: "subject")

    sign_in_as(@me)
    delete fd_case_participant_path(@kase, "UTHEIRS"), params: { role: "subject" }

    assert_equal 1, Fd::CaseParticipant.where(case_id: other.id, user_id: "UTHEIRS").count,
      "the case in the url must own the row"
  end
end
