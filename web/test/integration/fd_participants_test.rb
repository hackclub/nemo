require "test_helper"

class FdParticipantsTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @kase = make_case
  end

  def add(**params)
    post fd_case_participants_path(@kase),
      params: { user_id: "UNEW", role: "involved", detail: "they piled on" }.merge(params)
  end

  def people
    Fd::CaseParticipant.where(case_id: @kase.id).where.not(user_id: "USUB")
  end

  test "a signed out visitor cannot add anybody" do
    add
    assert_redirected_to login_path
    assert_empty people.to_a
  end

  test "somebody involved is recorded with how they were involved" do
    sign_in_as(@me)
    add(user_id: "UNEW", detail: "it was aimed at them")

    person = people.sole
    assert_equal "involved", person.role
    assert_equal "it was aimed at them", person.detail
    assert_match(/@UNEW added to who else was involved/, flash[:notice])
  end

  test "involved without a reason is allowed, the reason is optional" do
    sign_in_as(@me)
    add(detail: "  ")

    assert_equal "involved", people.sole.role
    assert_nil people.sole.detail
    assert_nil flash[:alert]
  end

  test "a reason typed against a role that has none is dropped rather than stored" do
    sign_in_as(@me)
    add(user_id: "UTOLDUS", role: "reporter", detail: "left over from the other option")

    assert_nil people.sole.detail
  end

  test "a second subject makes the case about both of them" do
    sign_in_as(@me)
    add(user_id: "USECOND", role: "subject", detail: "")

    assert_equal %w[USECOND USUB], @kase.reload.subject_user_ids
    assert_match(/the case is now also about @USECOND/, flash[:notice])
  end

  test "a reporter needs no reason" do
    sign_in_as(@me)
    add(user_id: "UTOLDUS", role: "reporter", detail: "")

    assert_equal "reporter", people.sole.role
    assert_nil people.sole.detail
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

  test "a role outside the three is refused" do
    sign_in_as(@me)
    add(role: "witness")

    assert_empty people.to_a
    assert_match(/pick how they were on this case/, flash[:alert])
  end

  test "adding the same person in the same role twice changes nothing" do
    sign_in_as(@me)
    add
    add

    assert_equal 1, people.count
    assert_nil flash[:alert], "a repeat is a no-op, not something to warn about"
    assert_match(/already on this case as involved, nothing changed/, flash[:notice])
  end

  test "one person can hold two roles on one case" do
    sign_in_as(@me)
    add(user_id: "UBOTH", role: "reporter", detail: "")
    add(user_id: "UBOTH", role: "involved", detail: "they were in the thread")

    assert_equal %w[involved reporter], people.map(&:role).sort
  end

  test "somebody else's case cannot be added to" do
    @kase.update!(claimed_by: "UOTHER", claimed_at: 1.hour.ago)
    sign_in_as(@me)
    add

    assert_empty people.to_a
    assert_match(/assigned to @UOTHER, not to you/, flash[:alert])
  end

  test "adding writes a trail entry filed under the case" do
    sign_in_as(@me)
    add(user_id: "UNEW")

    entry = Fd::AuditEntry.where(entity_type: "participant", entity_id: @kase.id,
      verb: "attached").sole
    assert_equal "UNEW", entry.after["user_id"]
    assert_equal "involved", entry.after["role"]
    assert_equal "UME", entry.actor_user_id
  end

  test "taking somebody off the case removes the row but not the record of it" do
    sign_in_as(@me)
    add(user_id: "UWRONG")
    delete fd_case_participant_path(@kase, "UWRONG"), params: { role: "involved" }

    assert_empty people.to_a
    entry = Fd::AuditEntry.where(entity_type: "participant", entity_id: @kase.id,
      verb: "detached").sole
    assert_equal "UWRONG", entry.before["user_id"]
    assert_nil entry.after
  end

  test "removing names the role, so the other one stays" do
    sign_in_as(@me)
    add(user_id: "UBOTH", role: "reporter", detail: "")
    add(user_id: "UBOTH", role: "involved", detail: "they were in the thread")

    delete fd_case_participant_path(@kase, "UBOTH"), params: { role: "reporter" }

    assert_equal ["involved"], people.map(&:role)
  end

  test "a mistaken subject can be taken back off" do
    sign_in_as(@me)
    add(user_id: "UINNOCENT", role: "subject", detail: "")
    delete fd_case_participant_path(@kase, "UINNOCENT"), params: { role: "subject" }

    assert_equal ["USUB"], @kase.reload.subject_user_ids
  end

  test "somebody who is not on the case cannot be removed from it" do
    sign_in_as(@me)
    delete fd_case_participant_path(@kase, "USTRANGER"), params: { role: "involved" }
    assert_match(/not on this case/, flash[:alert])
  end

  test "a member on another case cannot be removed through this one" do
    other = make_case(subject: "UELSE", opened_at: 1.day.ago)
    Fd::CaseParticipant.create!(case_id: other.id, user_id: "UTHEIRS", role: "involved",
      detail: "not our business")

    sign_in_as(@me)
    delete fd_case_participant_path(@kase, "UTHEIRS"), params: { role: "involved" }

    assert_equal 1, Fd::CaseParticipant.where(case_id: other.id, user_id: "UTHEIRS").count,
      "the case in the url must own the row"
  end

  test "the page offers the modal and lists how each person was involved" do
    Fd::CaseParticipant.create!(case_id: @kase.id, user_id: "UWATCHER", role: "involved",
      detail: "they piled on")
    sign_in_as(@me)
    get fd_case_path(@kase)

    assert_select "input#add-person.modal-flip"
    assert_select "form[action=?] input[name=user_id]", fd_case_participants_path(@kase)
    assert_select ".seg-radio input[name=role][value=involved][checked]"
    assert_select ".seg-radio input[name=role][value=subject]"
    assert_select "#who-else .who-row .who-name", text: "@UWATCHER"
    assert_select "#who-else .who-row .who-note", text: "they piled on"
    assert_select "#who-else .who-row .chip.chip-warn", text: "involved"
  end
end
