require "test_helper"

class FdMemberStandingTest < ActionDispatch::IntegrationTest
  WHO = "USUB".freeze

  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def deactivation(**attrs)
    Fd::MemberGuard.create!({
      kind: "deactivation", subject_id: WHO, opened_by: "UFF1", reason: "raiding",
      enforced_by: "nemo", enforcement_status: "pending"
    }.merge(attrs))
  end

  test "the frame links out to the whole page, so a case link is not lost in it" do
    deactivation
    get fd_member_standing_path(WHO)

    assert_response :success
    assert_select %(turbo-frame#member-standing-#{WHO}[target="_top"])
  end

  test "a guard nemo has not carried yet reads as asked, not as done" do
    deactivation
    get fd_member_standing_path(WHO)

    assert_select %(.standing-row[data-enforcement-status="pending"])
    assert_select ".enforcement-state", "Asking Slack"
  end

  test "a guard slack confirmed reads as held, and says so once it just landed" do
    deactivation(enforcement_status: "held")
    get fd_member_standing_path(WHO)

    assert_select %(.standing-row[data-enforcement-status="held"][data-landed="true"])
    assert_select ".enforcement-state", "Deactivated in Slack"
  end

  test "a guard that landed a while ago does not animate again" do
    guard = deactivation(enforcement_status: "held")
    guard.update_columns(updated_at: 1.hour.ago)
    get fd_member_standing_path(WHO)

    assert_select %(.standing-row[data-landed="false"])
  end

  test "one waiting on slack to put the account back says that, not that it is lifted" do
    deactivation(enforcement_status: "held", state: "lifting", lifted_by: "UME")
    get fd_member_standing_path(WHO)

    assert_select %(.standing-row[data-enforcement-status="lifting"])
    assert_select ".enforcement-state", "Putting the account back"
  end

  test "a failed carry shows what slack said" do
    deactivation(enforcement_status: "failed", last_error: "failed: user_not_found")
    get fd_member_standing_path(WHO)

    assert_select %(.standing-row[data-enforcement-status="failed"])
    assert_select ".enforcement-why", "failed: user_not_found"
  end

  test "a shush is not dressed up as a carried deactivation" do
    Fd::MemberGuard.create!(kind: "shush", subject_id: WHO, opened_by: "UFF1",
      reason: "spam", enforced_by: "nemo", enforcement_status: "held", expires_at: 3.days.from_now)
    get fd_member_standing_path(WHO)

    assert_select ".standing-row.is-enforced", false
    assert_select ".enforcement-state", false
  end

  test "a role the capability was taken from is not offered the button" do
    them = hold_role!("UOBS", "firefighter")
    Authz::Override.create!(role: "firefighter", capability: "member.deactivate",
      allowed: false, changed_by: "UME")
    sign_in_as(them)
    deactivation

    get fd_member_standing_path(WHO)
    assert_select %([data-modal-open^="guard-lift-"]), false
  end

  test "the member page carries the standing frame and the stream it listens on" do
    get fd_member_path(WHO)

    assert_select %(turbo-frame#member-standing-#{WHO})
    assert_select %([data-pending-flush-frame-value="member-standing-#{WHO}"])
    assert_select "turbo-cable-stream-source"
  end

  test "the deactivate modal asks for the handle back before it will go" do
    get fd_member_path(WHO)

    assert_select %(#member-deactivate)
    assert_select %([data-controller="confirm-word"])
    assert_select %(input[data-confirm-word-target="go"][disabled])
  end

  test "the modal is gone once a deactivation is already standing" do
    deactivation
    get fd_member_path(WHO)

    assert_select %(#member-deactivate), false
  end

  def deactivate(**params)
    post fd_member_guards_path(WHO), params: {
      kind: "deactivation", reason: "raiding"
    }.merge(params)
  end

  test "a deactivation with no date stands until somebody lifts it" do
    deactivate

    guard = Fd::MemberGuard.find_by(subject_id: WHO, kind: "deactivation")
    assert_not_nil guard
    assert_nil guard.expires_at
    assert_equal "live", guard.state
    assert_empty Fd::MemberGuard.where("expires_at IS NOT NULL"), "nothing for the sweep to lapse"
  end

  test "a deactivation with a date runs until it" do
    deactivate(expires_on: "2027-01-09")

    guard = Fd::MemberGuard.find_by(subject_id: WHO, kind: "deactivation")
    assert_equal Date.new(2027, 1, 9), guard.expires_at.to_date
  end

  test "a date that is not a date is refused rather than read as no end" do
    deactivate(expires_on: "the ninth")

    assert_nil Fd::MemberGuard.find_by(subject_id: WHO, kind: "deactivation")
    assert_match(/not a date/, flash[:alert])
  end

  test "a shush still has to say when it runs until" do
    post fd_member_guards_path(WHO), params: { kind: "shush", reason: "spam" }

    assert_nil Fd::MemberGuard.find_by(subject_id: WHO, kind: "shush")
    assert_match(/say the date it runs until/, flash[:alert])
  end

  test "the notify payload names the member the guard is about" do
    assert_equal "USUB", Fd::MemberGuardBroadcast.subject_from("usub")
    assert_nil Fd::MemberGuardBroadcast.subject_from("")
    assert_nil Fd::MemberGuardBroadcast.subject_from("2633")
  end
end
