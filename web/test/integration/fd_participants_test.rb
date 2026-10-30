require "test_helper"

class FdParticipantsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    @kase = make_case
  end

  def add(**params)
    post fd_case_participants_path(@kase),
      params: { user_id: "UNEW" }.merge(params)
  end

  def extra_participants
    Fd::CaseParticipant.where(case_id: @kase.id).where.not(user_id: "USUB")
  end

  test "create signed out redirects to login and adds no participant" do
    add
    assert_redirected_to login_path
    assert_empty extra_participants.to_a
  end

  test "create adds the user as a subject" do
    sign_in_as(@me)
    add(user_id: "UNEW")

    assert_equal "subject", extra_participants.sole.role
    assert_match(/@UNEW added to case/, flash[:notice])
  end

  test "create with role reporter adds a subject" do
    sign_in_as(@me)
    add(user_id: "UTOLDUS", role: "reporter")

    assert_equal "subject", extra_participants.sole.role,
      "role param does not set the participant role"
  end

  test "create with a second user adds a second subject to the case" do
    sign_in_as(@me)
    add(user_id: "USECOND")

    assert_equal %w[USECOND USUB], @kase.reload.subject_user_ids
    assert_match(/@USECOND added to case/, flash[:notice])
  end

  test "create normalizes an at-prefixed lower case user_id" do
    sign_in_as(@me)
    add(user_id: "  @unew  ")

    assert_equal "UNEW", extra_participants.sole.user_id
  end

  test "create with a non member id user_id is refused" do
    sign_in_as(@me)
    add(user_id: "bob")

    assert_empty extra_participants.to_a
    assert_match(/Not a Slack member ID/, flash[:alert])
  end

  test "create with role witness adds a subject without alert" do
    sign_in_as(@me)
    add(role: "witness")

    assert_equal "subject", extra_participants.sole.role
    assert_nil flash[:alert]
  end

  test "create twice with the same user keeps one participant" do
    sign_in_as(@me)
    add
    add

    assert_equal 1, extra_participants.count
    assert_nil flash[:alert], "no alert for an already added user"
    assert_match(/Already added/, flash[:notice])
  end

  test "create with user_ids adds every user as a subject" do
    sign_in_as(@me)
    post fd_case_participants_path(@kase),
      params: { user_ids: %w[UONE UTWO UTHREE], role: "subject" }

    assert_equal %w[UONE UTHREE UTWO], extra_participants.map(&:user_id).sort
    assert_match(/@UONE, @UTWO, and @UTHREE added to case/, flash[:notice])
  end

  test "create with user_ids including an existing participant adds the others" do
    sign_in_as(@me)
    add(user_id: "UONE")
    post fd_case_participants_path(@kase),
      params: { user_ids: %w[UONE UTWO], role: "subject" }

    assert_equal %w[UONE UTWO], extra_participants.map(&:user_id).sort,
      "existing participant does not abort the batch"
    assert_match(/@UTWO added to case · 1 already added/, flash[:notice])
  end

  test "create with one invalid id in user_ids adds no participant" do
    sign_in_as(@me)
    post fd_case_participants_path(@kase),
      params: { user_ids: %w[UONE bob], role: "subject" }

    assert_empty extra_participants.to_a
    assert_match(/Not a Slack member ID/, flash[:alert])
  end

  test "participant can have subject and reporter roles on one case" do
    sign_in_as(@me)
    add(user_id: "UBOTH")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "reporter")

    assert_equal %w[reporter subject], extra_participants.map(&:role).sort
  end

  test "create on a case assigned to another user adds the participant" do
    @kase.assign!("UOTHER")
    sign_in_as(@me)
    add

    assert_equal 1, extra_participants.count
    assert_match(/@UNEW added to case/, flash[:notice])
  end

  test "create writes an attached audit entry for the case" do
    sign_in_as(@me)
    add(user_id: "UNEW")

    entry = Fd::AuditEntry.where(entity_type: "participant", entity_id: @kase.id,
      verb: "attached").sole
    assert_equal "UNEW", entry.after["user_id"]
    assert_equal "subject", entry.after["role"]
    assert_equal "UME", entry.actor_user_id
  end

  test "destroy removes the participant and writes a detached audit entry" do
    sign_in_as(@me)
    add(user_id: "UWRONG")
    delete fd_case_participant_path(@kase, "UWRONG"), params: { role: "subject" }

    assert_empty extra_participants.to_a
    entry = Fd::AuditEntry.where(entity_type: "participant", entity_id: @kase.id,
      verb: "detached").sole
    assert_equal "UWRONG", entry.before["user_id"]
    assert_nil entry.after
  end

  test "destroy with role reporter keeps the subject row" do
    sign_in_as(@me)
    add(user_id: "UBOTH")
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UBOTH", role: "reporter")

    delete fd_case_participant_path(@kase, "UBOTH"), params: { role: "reporter" }

    assert_equal ["subject"], extra_participants.map(&:role)
  end

  test "destroy removes an added subject from subject_user_ids" do
    sign_in_as(@me)
    add(user_id: "UINNOCENT", role: "subject")
    delete fd_case_participant_path(@kase, "UINNOCENT"), params: { role: "subject" }

    assert_equal ["USUB"], @kase.reload.subject_user_ids
  end

  test "destroy for a user not on the case sets alert" do
    sign_in_as(@me)
    delete fd_case_participant_path(@kase, "USTRANGER"), params: { role: "subject" }
    assert_match(/Not a participant/, flash[:alert])
  end

  test "destroy for a participant of another case keeps the row" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    Fd::CaseParticipant.create!(case_id: other.id, user_id: "UTHEIRS", role: "subject")

    sign_in_as(@me)
    delete fd_case_participant_path(@kase, "UTHEIRS"), params: { role: "subject" }

    assert_equal 1, Fd::CaseParticipant.where(case_id: other.id, user_id: "UTHEIRS").count,
      "the case in the url must own the row"
  end
end
