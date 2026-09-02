require "test_helper"

class Fd::AccessGrantTest < ActiveSupport::TestCase
  def give(user_id = "UFF1", role: "firefighter", **attrs)
    Fd::AccessGrant.give!(user_id, role: role, by: "UBOSS", **attrs)
  end

  test "a grant says who gave it, when, and why" do
    grant = give("UFF1", reason: "night shift while sam is away")

    assert_predicate grant, :live?
    assert_equal "firefighter", grant.role
    assert_equal "UBOSS", grant.granted_by
    assert_equal "night shift while sam is away", grant.reason
    assert_equal "firefighter", Fd::AccessGrant.role_for("UFF1")
  end

  test "one person holds one live grant, and a change ends the old one" do
    first = give("UFF1", role: "firefighter")
    second = give("UFF1", role: "lead", reason: "promoted")

    assert_predicate first.reload, :revoked?
    assert_equal "UBOSS", first.revoked_by
    assert_predicate second, :live?
    assert_equal "lead", Fd::AccessGrant.role_for("UFF1")
    assert_equal 2, Fd::AccessGrant.for_person("UFF1").count
  end

  test "the database refuses two live grants, whatever the code does" do
    give("UFF1")

    assert_raises(ActiveRecord::RecordNotUnique) do
      Fd::AccessGrant.create!(user_id: "UFF1", role: "lead", granted_by: "UBOSS")
    end
  end

  test "taking a grant back leaves a line rather than a gap" do
    grant = give("UFF1")
    grant.take_back!(by: "UBOSS")

    assert_nil Fd::AccessGrant.role_for("UFF1")
    assert_equal 1, Fd::AccessGrant.for_person("UFF1").count
    assert_predicate grant, :revoked?
    assert_raises(Fd::AccessGrant::NotAllowed) { grant.take_back!(by: "UBOSS") }
  end

  test "a role nobody offered is refused" do
    assert_raises(Fd::AccessGrant::NotAllowed) { give("UFF1", role: "admin") }
    assert_equal 0, Fd::AccessGrant.for_person("UFF1").count
  end

  test "a blank reason is stored as nothing, not as empty text" do
    assert_nil give("UFF1", reason: "   ").reason
  end

  test "roles come back for a whole roster in one query" do
    give("UFF1", role: "firefighter")
    give("ULEAD", role: "lead")

    assert_equal({ "UFF1" => "firefighter", "ULEAD" => "lead" },
      Fd::AccessGrant.roles_for(["UFF1", "ULEAD", "UNOBODY"]))
  end

  test "the grant decides what somebody may do" do
    staff = Staff.create!(user_id: "UFF1", community_manager: false)
    assert_nil staff.role
    assert_not staff.may?("case.act")

    give("UFF1", role: "firefighter")
    fresh = Staff.find("UFF1")
    assert_equal "firefighter", fresh.role
    assert fresh.may?("case.act")
    assert_not fresh.may?("decision.settle")

    give("UFF1", role: "lead")
    assert_predicate Staff.find("UFF1"), :lead?
  end

  test "a community manager holds the tool from the flag, with no grant row" do
    boss = Staff.create!(user_id: "UBOSS2", community_manager: true)

    assert_nil boss.role
    assert_predicate boss, :manager?
    assert boss.may?("access.grant")
    assert_equal 0, Fd::AccessGrant.live.for_person("UBOSS2").count
  end

  test "the manager role is held by the flag, never handed out as a grant" do
    assert_raises(Fd::AccessGrant::NotAllowed) do
      Fd::AccessGrant.give!("UFF1", role: "community_manager", by: "UBOSS")
    end
  end

  test "how long a grant was held is answerable after it ends" do
    grant = give("UFF1", at: 10.days.ago)
    assert_in_delta 10.days, grant.held_for, 5

    grant.take_back!(by: "UBOSS", at: 3.days.ago)
    assert_in_delta 7.days, grant.held_for, 5
  end
end
