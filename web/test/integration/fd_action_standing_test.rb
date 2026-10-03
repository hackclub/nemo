require "test_helper"

class FdActionStandingTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
    @kase = make_case(opened_at: 3.days.ago)
  end

  def guard!(**over)
    Fd::MemberGuard.create!({
      kind: "shush", subject_id: "USUB", opened_by: "UMOD",
      reason: "being awful", expires_at: 7.days.from_now
    }.merge(over))
  end

  def look(**params)
    get fd_case_standing_path(@kase), params: { target_user_id: "USUB" }.merge(params)
  end

  def offered
    response.body.scan(/name="standing_guard_id" value="(\d*)"/).flatten
  end

  def a_named_channel
    Analytics::DimChannel.where.not(name: nil).first
  end

  test "a channel-scoped guard is named by its channel, not left unnamed" do
    room = a_named_channel
    guard!(kind: "channel_ban", channel_id: room.channel_id)
    look

    assert_match(/##{room.name}/, response.body)
    assert_no_match(/unnamed channel/, response.body)
  end

  test "the case page names the channel a standing guard is scoped to" do
    room = a_named_channel
    guard!(kind: "channel_ban", channel_id: room.channel_id, case_id: @kase.id)
    get fd_case_path(@kase, do: "action")

    assert_match(/##{room.name}/, response.body)
    assert_no_match(/unnamed channel/, response.body)
  end

  test "a guard already on this case is offered but cannot be picked" do
    guard = guard!(case_id: @kase.id)
    look

    assert_select %(input[name="standing_guard_id"][value="#{guard.id}"][disabled])
    assert_match(/already on this case/, response.body)
  end

  test "a guard held elsewhere but logged here is greyed out too" do
    other = make_case
    guard = guard!(case_id: other.id)
    post fd_case_actions_path(@kase),
      params: { standing_guard_id: guard.id, target_user_id: "USUB" }
    look

    assert_select %(input[name="standing_guard_id"][value="#{guard.id}"][disabled])
    assert_match(/already logged on this case/, response.body)
  end

  test "a guard on another case stays pickable here" do
    other = make_case
    guard = guard!(case_id: other.id)
    look

    assert_select %(input[name="standing_guard_id"][value="#{guard.id}"][disabled]), false
  end

  test "nobody named yet offers nothing" do
    guard!
    look(target_user_id: "")
    assert_response :success
    assert_empty offered
  end

  test "somebody with nothing standing is offered nothing" do
    look
    assert_response :success
    assert_empty offered
  end

  test "everything standing on them is offered, whatever kind" do
    one = guard!
    two = guard!(kind: "channel_ban", channel_id: "C0266FRGV")
    look

    assert_equal [one.id.to_s, two.id.to_s, ""], offered
    assert_match(/None of these/, response.body)
  end

  test "a lifted guard is not offered" do
    guard!(state: "lifted", lifted_at: Time.current, lifted_by: "UMOD")
    look
    assert_empty offered
  end

  test "one still being lifted is still offered" do
    held = guard!(state: "lifting", lifted_by: "UMOD")
    look
    assert_includes offered, held.id.to_s
  end

  test "each one says which case it sits on" do
    guard!
    look
    assert_match(/on no case/, response.body)

    other = make_case
    Fd::MemberGuard.update_all(case_id: other.id)
    look
    assert_match(/on case #{other.id}/, response.body)
  end

  test "one on this case says so" do
    guard!(case_id: @kase.id)
    look
    assert_match(/on this case/, response.body)
  end

  test "the note says which case and until when, and nothing about nemo" do
    guard!(carry: "failed", expires_at: Time.utc(2026, 3, 10))
    look

    assert_match(/on no case/, response.body)
    assert_match(/until 10 Mar/, response.body)
    assert_no_match(/nemo/, response.body)
  end

  test "one with no end date says so" do
    guard!(expires_at: nil)
    look
    assert_match(/no end date/, response.body)
  end

  test "the list is asked for by member alone, not by kind" do
    guard!(kind: "channel_ban", channel_id: "C0266FRGV")
    look
    assert_equal 1, offered.count { |one| one.present? },
      "a channel ban shows even though no kind was named"
  end

  test "a signed out visitor is told nothing about who is standing" do
    guard!
    delete logout_path
    look
    assert_redirected_to login_path
    assert_empty offered
  end
  test "the modal asks who first, then what is standing, then the fields" do
    guard!
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_operator body.index('data-member-picker-name-value="target_user_id"'), :<,
      body.index('turbo-frame id="action-standing"')
    assert_operator body.index('turbo-frame id="action-standing"'), :<,
      body.index('data-action-standing-target="fields"')
  end

  test "the fields collapse under a chosen guard, and the frame reloads on a member" do
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/data-action-standing-target="fields"/, body)
    assert_match(/action-standing#fit/, body) if Fd::MemberGuard.any?
    assert_match(/member-picker:picked->action-standing#look/, body)
    assert_match(/turbo:frame-load->action-standing#fit/, body)
  end

  test "a case with one subject already shows what is standing on them" do
    kase = make_case(subject: "USUB")
    guard!
    get fd_case_path(kase, do: "action")

    assert_match(/None of these/, response.body)
    assert_match(/name="standing_guard_id"/, response.body)
  end

  test "a case with no subject asks nothing until somebody is named" do
    bare = make_case(subject: nil)
    guard!
    get fd_case_path(bare, do: "action")
    assert_no_match(/name="standing_guard_id"/, response.body)
  end
  test "each kind carries whether it expires, takes a channel, or reads a lock" do
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/data-expires="false" data-channel="false" data-lock="false" value="warning"/,
      body)
    assert_match(/data-expires="true" data-channel="false" data-lock="false" value="shush"/, body)
    assert_match(/data-expires="true" data-channel="true" data-lock="false" value="channel_ban"/,
      body)
    assert_match(
      /data-expires="false" data-channel="false" data-lock="true" value="locked_thread"/, body
    )
  end

  test "the date and channel start hidden and are shaped by the kind" do
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/data-action-standing-target="expiry" hidden/, body)
    assert_match(/data-action-standing-target="channel" hidden/, body)
    assert_match(/action-standing#shape/, body)
  end
  test "the channel field searches rather than asking for an id" do
    get fd_case_path(@kase, do: "action")
    body = response.body

    assert_match(/data-controller="channel-picker"/, body)
    assert_match(/data-channel-picker-name-value="channel_id"/, body)
    assert_no_match(/placeholder="C0266FRGV"/, body)
  end

  test "each option is a house radio row, not a browser one" do
    guard!
    look

    assert_match(/class="opt-dot"/, response.body)
    assert_match(/class="opt-label"/, response.body)
    assert_match(/class="opt-note"/, response.body)
  end
end
