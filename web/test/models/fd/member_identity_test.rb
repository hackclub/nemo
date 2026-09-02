require "test_helper"

class Fd::MemberIdentityTest < ActiveSupport::TestCase
  setup do
    @me = hold_role!("UME", "community_manager")
  end

  test "the app holds no write grant on either member table" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Fd::Member.insert!({ user_id: "USNEAK", display_name: "Sneak" })
    end

    assert_raises(ActiveRecord::StatementInvalid) do
      Fd::MemberIdentity.insert!({ user_id: "USNEAK", email: "sneak@example.invalid" })
    end
  end

  test "a loaded member row is readonly, so nothing can save one by accident" do
    assert Fd::Member.new(user_id: "U1").tap { |row| row.instance_variable_set(:@new_record, false) }
      .readonly?
    assert Fd::MemberIdentity.new(user_id: "U1")
      .tap { |row| row.instance_variable_set(:@new_record, false) }.readonly?
  end

  test "reading an identity without an actor is refused, not quietly allowed" do
    assert_raises(Fd::MemberIdentity::NoActor) do
      Fd::MemberIdentity.look_up("UMEMBER", actor: nil)
    end
  end

  test "a miss is still logged, since asking is the thing worth recording" do
    before = AccessLog.count
    assert_nil Fd::MemberIdentity.look_up("UNOBODY", actor: @me)

    entry = AccessLog.order(:id).last
    assert_equal before + 1, AccessLog.count
    assert_equal "UME", entry.actor_id
    assert_equal "UNOBODY", entry.subject_user_id
    assert_equal "identity", entry.field_class
  end

  test "somebody whose role does not carry identity.read is handed nothing" do
    them = Account.create!(user_id: "UFF1")
    hold_role!("UFF1", "firefighter")
    move_capability!("firefighter", "identity.read", false, by: "UME")
    before = AccessLog.count

    row = Fd::MemberIdentity.look_up(Fd::Member.order(:user_id).first.user_id, actor: them)

    assert row.refused?
    assert_nil row.email
    assert_equal before, AccessLog.count, "a read that did not happen must not be logged"
  end

  test "a read that is allowed is not marked refused" do
    assert_not Fd::MemberIdentity.look_up("UNOBODY", actor: @me)&.refused?
    assert_not Fd::MemberIdentity.look_up(Fd::Member.order(:user_id).first.user_id,
      actor: @me).refused?
  end

  test "the trail redacts every identity column, so an email cannot reach it" do
    assert_equal %w[real_name first_name last_name email],
      Fd::Audit::REDACTED_COLUMNS.fetch("identity")
    assert_equal "identity", Fd::Audit.entity_type(Fd::MemberIdentity.new)
  end

  test "no phone is stored, because a conduct tool has no use for one" do
    assert_not Fd::MemberIdentity.column_names.include?("phone")
  end

  test "a member falls back through display name, handle, then the raw id" do
    assert_equal "Ada", Fd::Member.new(display_name: "Ada", handle: "ada").name
    assert_equal "ada", Fd::Member.new(display_name: "", handle: "ada").name
    assert_equal "@UBARE", Fd::Member.new(user_id: "UBARE").name
  end

  test "identity is separately granted, so a member row carries no personal name" do
    assert_not Fd::Member.column_names.intersect?(%w[real_name first_name last_name email])
  end

  test "reading a seeded identity hands back the row and logs who looked" do
    seeded = Fd::Member.order(:user_id).first
    before = AccessLog.count

    row = Fd::MemberIdentity.look_up(seeded.user_id, actor: @me)

    assert_equal seeded.user_id, row.user_id
    assert_match(/\A\w+ \w+\z/, row.real_name)
    assert_equal before + 1, AccessLog.count
    assert_equal seeded.user_id, AccessLog.order(:id).last.subject_user_id
  end

  test "the corpus never carries a deliverable address" do
    assert_equal 0, Fd::MemberIdentity.where.not(email: nil)
      .where.not("email LIKE '%@example.invalid'").count
  end

  test "every seeded member has an identity row, and they agree" do
    assert_equal Fd::Member.count, Fd::MemberIdentity.count
    assert_equal 0, Fd::Member.joins(:identity)
      .where.not("fd.member_identity.email = fd.member.handle || '@example.invalid'").count
  end

  test "some members have no display name, so the fallback is exercised by the corpus" do
    assert_operator Fd::Member.where(display_name: "").count, :>, 0
  end
end
