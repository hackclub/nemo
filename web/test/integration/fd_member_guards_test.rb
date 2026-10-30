require "test_helper"

class FdMemberGuardsTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def guard!(**over)
    Fd::MemberGuard.create!({
      kind: "shush", subject_id: "USUB", opened_by: "UMOD",
      reason: "being awful", expires_at: 7.days.from_now
    }.merge(over))
  end

  def create_guard(**params)
    post fd_member_guards_path("USUB"), params: {
      kind: "shush", reason: "would not let it go",
      expires_on: 7.days.from_now.to_date.to_s
    }.merge(params)
  end

  def guards = Fd::MemberGuard.for_subject("USUB")

  def audit_entries(verb)
    Fd::AuditEntry.where(entity_type: "member_guard", verb: verb)
  end

  test "create shush without case creates orphaned pending guard and audit entry" do
    create_guard
    guard = guards.sole
    assert_nil guard.case_id
    assert guard.orphaned?
    assert_equal "pending", guard.enforcement_status
    assert_equal "UME", guard.opened_by
    assert_equal 1, audit_entries("opened").count
  end

  test "create channel_ban requires channel_id and shush clears channel_id" do
    create_guard(kind: "channel_ban")
    assert_empty guards

    create_guard(kind: "channel_ban", channel_id: "C0266FRGV")
    assert_equal "C0266FRGV", guards.sole.channel_id

    create_guard(kind: "shush", channel_id: "C0266FRGV")
    assert_nil guards.find_by(kind: "shush").channel_id
  end

  test "create with blank reason creates no guard" do
    create_guard(reason: "  ")
    assert_empty guards
  end

  test "create with expires_on and expires_time sets expires_at in utc" do
    create_guard(expires_on: "2026-11-02", expires_time: "08:15")

    assert_equal Time.utc(2026, 11, 2, 8, 15), guards.sole.expires_at
  end

  test "create with invalid expires_time creates no guard and sets alert" do
    create_guard(expires_time: "25:00")

    assert_empty guards
    assert_equal "25:00 is not a time", flash[:alert]
  end

  test "create with unknown kind creates no guard" do
    create_guard(kind: "banishment")
    assert_empty guards
  end

  test "create second guard for the same subject creates no row" do
    guard!
    create_guard
    assert_equal 1, guards.count
  end

  test "create channel_ban in two channels creates two guards" do
    create_guard(kind: "channel_ban", channel_id: "C0266FRGV")
    create_guard(kind: "channel_ban", channel_id: "CELSEWHERE")
    assert_equal 2, guards.count
  end

  test "destroy marks guard lifted with lift_reason and writes lifted audit entry" do
    guard = guard!
    delete fd_member_guard_path("USUB", guard), params: { lift_reason: "they apologised" }

    guard.reload
    assert_equal "lifted", guard.state
    assert_equal "UME", guard.lifted_by
    assert_equal "they apologised", guard.lift_reason
    assert_equal "being awful", guard.reason
    assert_equal 1, audit_entries("lifted").count
    assert_empty Fd::MemberGuard.active.for_subject("USUB")
  end

  test "create after destroy adds a row and leaves one active guard" do
    guard = guard!
    delete fd_member_guard_path("USUB", guard)
    create_guard
    assert_equal 2, guards.count
    assert_equal 1, Fd::MemberGuard.active.for_subject("USUB").count
  end

  test "update expires_on changes expires_at and writes extended audit entry" do
    guard = guard!
    new_expiry = 30.days.from_now.to_date
    patch fd_member_guard_path("USUB", guard), params: { expires_on: new_expiry.to_s }

    assert_equal new_expiry, guard.reload.expires_at.to_date
    assert_equal 1, audit_entries("extended").count
  end

  test "update with expires_on in next year puts year in notice" do
    guard = guard!
    new_expiry = Date.new(Date.current.year + 1, 10, 15)

    patch fd_member_guard_path("USUB", guard), params: { expires_on: new_expiry.to_s }

    assert_equal "Shush extended · ends 15 Oct #{new_expiry.year}", flash[:notice]
  end

  test "member page with guard expiring in next year shows year" do
    expiry = Time.zone.local(Date.current.year + 1, 10, 15, 12)
    guard!(expires_at: expiry)

    get fd_member_path("USUB")

    assert_includes response.body, "until 15 Oct #{expiry.year}"
  end

  test "destroy and update on a lifted guard return 404" do
    guard = guard!(state: "lifted", lifted_at: Time.current, lifted_by: "UMOD")

    delete fd_member_guard_path("USUB", guard)
    assert_response :not_found

    patch fd_member_guard_path("USUB", guard), params: { expires_on: 30.days.from_now.to_date.to_s }
    assert_response :not_found
    assert_equal "UMOD", guard.reload.lifted_by
  end

  test "create without member.guard creates no guard" do
    revoke_roles!("UME")
    grant_role!("UME", "gardener")
    create_guard
    assert_empty guards
  end

  test "member page renders guard modal button for community_manager and firefighter" do
    get fd_member_path("USUB")
    assert_match(/data-modal-open="member-guard"/, response.body)

    revoke_roles!("UME")
    grant_role!("UME", "firefighter")
    get fd_member_path("USUB")
    assert_match(/data-modal-open="member-guard"/, response.body)
  end

  test "member page lists active guard with lift control and no case label" do
    guard = guard!
    get fd_member_path("USUB")
    assert_select ".standing-t", /Guards/
    assert_match(/guard-lift-#{guard.id}/, response.body)
    assert_match(/on no case/, response.body)
  end
  test "member page guard modal renders picker menu and hidden channel field" do
    get fd_member_path("USUB")

    assert_match(/data-controller="picker menu"/, response.body)
    assert_match(/data-guard-form-target="channel" hidden/, response.body)
    assert_match(/data-combobox-kind-value="channel"/, response.body)
  end

  test "member page guard modal renders no settle field" do
    get fd_member_path("USUB")
    assert_no_match(/AlreadyError taken/, response.body)
    assert_no_match(/name="settle"/, response.body)
  end

  test "create sets enforced_by nemo and pending enforcement_status" do
    create_guard
    assert_equal "nemo", guards.sole.enforced_by
    assert_equal "pending", guards.sole.enforcement_status
  end

  test "channel search returns channels array" do
    get fd_channel_search_path, params: { q: "" }
    assert_response :success
    assert_kind_of Array, response.parsed_body["channels"]
  end

  test "channel search signed out redirects to login" do
    delete logout_path
    get fd_channel_search_path, params: { q: "" }
    assert_redirected_to login_path
  end

  test "member page labels a firehose guard and offers no lift" do
    guard = guard!(enforced_by: "firehose", enforcement_status: "held")

    get fd_member_path("USUB")

    assert_match(/Firehose/, response.body)
    assert_no_match(/guard-lift-#{guard.id}/, response.body)
  end

  test "destroy on a firehose guard leaves it live" do
    guard = guard!(enforced_by: "firehose", enforcement_status: "held")

    delete fd_member_guard_path("USUB", guard), params: { lift_reason: "done" }

    assert_redirected_to fd_member_path("USUB")
    assert_equal "Set in Firehose", flash[:alert]
    assert_equal "live", guard.reload.state
  end

  test "update on a firehose guard keeps its end" do
    guard = guard!(enforced_by: "firehose", enforcement_status: "held")
    expires_at = guard.expires_at

    patch fd_member_guard_path("USUB", guard), params: { expires_on: 30.days.from_now.to_date.to_s }

    assert_equal "Set in Firehose", flash[:alert]
    assert_equal expires_at.to_i, guard.reload.expires_at.to_i
  end
end
