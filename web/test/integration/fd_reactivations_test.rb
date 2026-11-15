require "test_helper"

class FdReactivationsTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  SUBJECT = "UREACT01".freeze

  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
    @kase = make_case(subject: SUBJECT)
  end

  def member_dim!(is_deleted:)
    as_pipeline("INSERT INTO raw.member_dim (user_id, invite_pending, claimed_at, is_deleted) VALUES (?, false, NULL, ?)",
      SUBJECT, is_deleted)
    seeded!("raw.member_dim", "user_id", SUBJECT)
  end

  def ban!(type_key, expires_at: nil, guard: nil)
    Fd::Action.create!(case_id: @kase.id, type_key: type_key, target_user_id: SUBJECT, decided_by: "UMOD",
      performed_by: "UMOD", performed_at: 3.days.ago, source_app: "lyla", expires_at: expires_at,
      guard_id: guard&.id)
  end

  def deactivation!(**over)
    Fd::MemberGuard.create!({ kind: "deactivation", subject_id: SUBJECT, opened_by: "UMOD", reason: "ban",
                              state: "live", enforced_by: "nemo", enforcement_status: "held" }.merge(over))
  end

  def guards = Fd::MemberGuard.for_subject(SUBJECT)

  test "reactivating a deactivated account with no guard records one, lifts it and ends its bans" do
    member_dim!(is_deleted: true)
    indefinite = ban!("indef_ban")
    served = ban!("temp_ban", expires_at: 1.day.ago)

    post fd_member_reactivation_path(SUBJECT), params: { reason: "appeal accepted" }

    guard = guards.sole
    assert_equal %w[deactivation lifting nemo held],
      [guard.kind, guard.state, guard.enforced_by, guard.enforcement_status]
    assert_equal ["UMOD", "Indefinite ban", @kase.id], [guard.opened_by, guard.reason, guard.case_id]
    assert_in_delta indefinite.performed_at, guard.opened_at, 1
    assert_equal "appeal accepted", guard.lift_reason
    assert_in_delta Time.current, indefinite.reload.expires_at, 10
    assert_not indefinite.reversed?
    assert_operator served.reload.expires_at, :<, 12.hours.ago
    assert_match(/\AReactivation queued for .+ · 1 ban ended\z/, flash[:notice])
    assert Fd::AuditEntry.exists?(entity_type: "member_guard", entity_id: guard.id, verb: "recorded")
    assert Fd::AuditEntry.exists?(entity_type: "member_guard", entity_id: guard.id, verb: "lifted")
    assert Fd::AuditEntry.exists?(entity_type: "action", entity_id: indefinite.id, verb: "ended")
  end

  test "reactivating an active account with no running bans says it is not deactivated" do
    member_dim!(is_deleted: false)

    post fd_member_reactivation_path(SUBJECT), params: { reason: "appeal accepted" }

    assert_match(/is not deactivated\z/, flash[:alert])
    assert_empty guards
  end

  test "reactivation needs a reason" do
    member_dim!(is_deleted: true)

    post fd_member_reactivation_path(SUBJECT), params: { reason: " " }

    assert_redirected_to fd_member_path(SUBJECT, do: "reactivate")
    assert_empty guards
  end

  test "reactivation needs member.deactivate" do
    member_dim!(is_deleted: true)
    firefighter = grant_role!("UFIRE", "firefighter")
    override_capability!("firefighter", "member.deactivate", false)
    sign_in_as(firefighter)

    post fd_member_reactivation_path(SUBJECT), params: { reason: "appeal accepted" }

    assert_empty guards
  end

  test "Reactivate on a Nemo deactivation lifts it and ends the member's bans" do
    guard = deactivation!
    ban = ban!("perma_ban", guard: guard)

    delete fd_member_guard_path(SUBJECT, guard), params: { lift_reason: "appeal accepted" }

    assert_equal "lifting", guard.reload.state
    assert_not_nil ban.reload.expires_at
    assert_match(/\AReactivation queued for .+ · 1 ban ended\z/, flash[:notice])
  end

  test "lifting a shush leaves bans running" do
    shush = Fd::MemberGuard.create!(kind: "shush", subject_id: SUBJECT, opened_by: "UMOD", reason: "loud",
      expires_at: 2.days.from_now)
    ban = ban!("indef_ban")

    delete fd_member_guard_path(SUBJECT, shush), params: { lift_reason: "calmed down" }

    assert_nil ban.reload.expires_at
  end

  test "cancelling a scheduled deactivation reverses its action" do
    guard = deactivation!(state: "scheduled", starts_at: 2.days.from_now, enforcement_status: "pending")
    ban = ban!("temp_ban", expires_at: 9.days.from_now, guard: guard)

    delete fd_member_guard_path(SUBJECT, guard), params: { cancel_reason: "changed our mind" }

    assert ban.reload.reversed?
    assert_equal "changed our mind", ban.reversal_reason
  end

  test "member page offers Reactivate for a deactivated account with no guard" do
    member_dim!(is_deleted: true)

    get fd_member_path(SUBJECT)

    assert_select "button[data-modal-open=member-reactivate]", text: /Reactivate/
    assert_select "form[action=?]", fd_member_reactivation_path(SUBJECT)
  end
end
