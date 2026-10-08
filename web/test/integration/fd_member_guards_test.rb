require "test_helper"

class FdMemberGuardsTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def guard!(**over)
    Fd::MemberGuard.create!({
      kind: "shush", subject_id: "USUB", opened_by: "UMOD",
      reason: "being awful", expires_at: 7.days.from_now
    }.merge(over))
  end

  def hold(**params)
    post fd_member_guards_path("USUB"), params: {
      kind: "shush", reason: "would not let it go",
      expires_on: 7.days.from_now.to_date.to_s
    }.merge(params)
  end

  def guards = Fd::MemberGuard.for_subject("USUB")

  def told(verb)
    Fd::AuditEntry.where(entity_type: "member_guard", verb: verb)
  end

  test "a shush can be held with no case behind it" do
    hold
    guard = guards.sole
    assert_nil guard.case_id
    assert guard.orphaned?
    assert_equal "pending", guard.enforcement_status
    assert_equal "UME", guard.opened_by
    assert_equal 1, told("opened").count
  end

  test "a channel ban needs a channel, a shush ignores one" do
    hold(kind: "channel_ban")
    assert_empty guards

    hold(kind: "channel_ban", channel_id: "C0266FRGV")
    assert_equal "C0266FRGV", guards.sole.channel_id

    hold(kind: "shush", channel_id: "C0266FRGV")
    assert_nil guards.find_by(kind: "shush").channel_id
  end

  test "it will not hold without a date or a reason" do
    hold(expires_on: "")
    assert_empty guards

    hold(reason: "  ")
    assert_empty guards
  end

  test "a kind nobody declared is refused" do
    hold(kind: "banishment")
    assert_empty guards
  end

  test "a second one on the same person is refused, not duplicated" do
    guard!
    hold
    assert_equal 1, guards.count
  end

  test "the same person can be held in two different channels" do
    hold(kind: "channel_ban", channel_id: "C0266FRGV")
    hold(kind: "channel_ban", channel_id: "CELSEWHERE")
    assert_equal 2, guards.count
  end

  test "lifting stops it standing and keeps the record" do
    guard = guard!
    delete fd_member_guard_path("USUB", guard), params: { lift_reason: "they apologised" }

    guard.reload
    assert_equal "lifted", guard.state
    assert_equal "UME", guard.lifted_by
    assert_equal "they apologised", guard.lift_reason
    assert_equal "being awful", guard.reason
    assert_equal 1, told("lifted").count
    assert_empty Fd::MemberGuard.still_on.for_subject("USUB")
  end

  test "a lifted one frees the person to be held again" do
    guard = guard!
    delete fd_member_guard_path("USUB", guard)
    hold
    assert_equal 2, guards.count
    assert_equal 1, Fd::MemberGuard.still_on.for_subject("USUB").count
  end

  test "the date it runs until can be changed" do
    guard = guard!
    fresh = 30.days.from_now.to_date
    patch fd_member_guard_path("USUB", guard), params: { expires_on: fresh.to_s }

    assert_equal fresh, guard.reload.expires_at.to_date
    assert_equal 1, told("extended").count
  end

  test "a lifted one cannot be lifted or re-dated again" do
    guard = guard!(state: "lifted", lifted_at: Time.current, lifted_by: "UMOD")

    delete fd_member_guard_path("USUB", guard)
    assert_response :not_found

    patch fd_member_guard_path("USUB", guard), params: { expires_on: 30.days.from_now.to_date.to_s }
    assert_response :not_found
    assert_equal "UMOD", guard.reload.lifted_by
  end

  test "somebody without member.guard cannot hold anything" do
    drop_roles!("UME")
    hold_role!("UME", "gardener")
    hold
    assert_empty guards
  end

  test "the page offers to take action only to somebody who may" do
    get fd_member_path("USUB")
    assert_match(/data-modal-open="member-guard"/, response.body)

    drop_roles!("UME")
    hold_role!("UME", "firefighter")
    get fd_member_path("USUB")
    assert_match(/data-modal-open="member-guard"/, response.body)
  end

  test "a live guard is shown on the page with a way to lift it" do
    guard = guard!
    get fd_member_path("USUB")
    assert_match(/In force now/, response.body)
    assert_match(/guard-lift-#{guard.id}/, response.body)
    assert_match(/on no case/, response.body)
  end
  test "the modal uses the house dropdown and hides the channel until it is wanted" do
    get fd_member_path("USUB")

    assert_match(/data-controller="picker menu"/, response.body)
    assert_match(/data-guard-form-target="channel" hidden/, response.body)
    assert_match(/data-combobox-kind-value="channel"/, response.body)
  end

  test "nothing is asked about enforcement, since holding it is the point" do
    get fd_member_path("USUB")
    assert_no_match(/AlreadyError taken/, response.body)
    assert_no_match(/name="settle"/, response.body)
  end

  test "what it holds is always carried by nemo" do
    hold
    assert_equal "nemo", guards.sole.enforced_by
    assert_equal "pending", guards.sole.enforcement_status
  end

  test "channels can be searched from inside the fire engine" do
    get fd_channel_search_path, params: { q: "" }
    assert_response :success
    assert_kind_of Array, response.parsed_body["channels"]
  end

  test "a signed out visitor cannot search channels" do
    delete logout_path
    get fd_channel_search_path, params: { q: "" }
    assert_redirected_to login_path
  end
end
