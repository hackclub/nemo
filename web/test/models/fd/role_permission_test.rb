require "test_helper"

class Fd::RolePermissionTest < ActiveSupport::TestCase
  def move(role, key, allowed)
    Fd::RolePermission.set!(role, key, allowed, by: "UME")
  end

  def refusal
    assert_raises(Fd::RolePermission::NotAllowed) { yield }.message
  end

  test "with nothing moved, the code defaults are the map" do
    assert_equal Fd::Permission::LEAD, Fd::Permission.roles("decision.settle")
    assert_equal Fd::Permission::ROLES, Fd::Permission.roles("case.act")
  end

  test "giving a permission to a role that did not hold it takes effect" do
    move("firefighter", "decision.settle", true)

    assert_equal Fd::Permission::ROLES, Fd::Permission.roles("decision.settle")
    assert_includes Fd::Permission.held_by("firefighter"), "decision.settle"
  end

  test "taking one away leaves the other roles alone" do
    move("firefighter", "case.reverse", false)

    assert_equal %w[lead community_manager], Fd::Permission.roles("case.reverse")
    assert_equal Fd::Permission::ROLES, Fd::Permission.roles("case.act")
  end

  test "a permission cannot be taken from the last role holding it" do
    move("firefighter", "decision.settle", false)
    move("lead", "decision.settle", false)

    assert_equal "decision.settle would then be held by nobody",
      refusal { move("community_manager", "decision.settle", false) }
    assert_equal %w[community_manager], Fd::Permission.roles("decision.settle")
  end

  test "access.grant cannot be moved, whichever way it is pushed" do
    assert_equal "access.grant cannot be moved", refusal { move("firefighter", "access.grant", true) }
    assert_equal "access.grant cannot be moved",
      refusal { move("community_manager", "access.grant", false) }
    assert_equal Fd::Permission::MANAGER, Fd::Permission.roles("access.grant")
  end

  test "the database refuses a locked key even if the model is bypassed" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Fd::RolePermission.create!(role: "firefighter", permission_key: "access.grant",
        allowed: true, changed_by: "UME")
    end
  end

  test "a role or key nobody has heard of is refused" do
    assert_equal "wizard is not a role", refusal { move("wizard", "case.act", true) }
    assert_equal "case.fly is not a permission", refusal { move("lead", "case.fly", true) }
  end

  test "moving the same pair twice keeps one row, not two" do
    move("firefighter", "decision.settle", true)
    move("firefighter", "decision.settle", false)

    assert_equal 1, Fd::RolePermission.where(permission_key: "decision.settle").count
    assert_equal Fd::Permission::LEAD, Fd::Permission.roles("decision.settle")
  end

  test "a key is marked moved only while it differs from the default" do
    assert_not Fd::RolePermission.moved?("decision.settle")

    move("firefighter", "decision.settle", true)
    assert Fd::RolePermission.moved?("decision.settle")

    move("firefighter", "decision.settle", false)
    assert_not Fd::RolePermission.moved?("decision.settle")
  end

  test "what a role may do follows the map, not the code" do
    staff = Staff.create!(user_id: "UFF9", community_manager: false)
    Fd::AccessGrant.give!("UFF9", role: "firefighter", by: "UME")

    assert staff.may?("decision.settle"), "a firefighter settles by default now"
    move("firefighter", "decision.settle", false)
    assert_not staff.reload.may?("decision.settle"), "an override takes it back off them"
    move("firefighter", "decision.settle", true)
    assert Staff.find("UFF9").may?("decision.settle")
  end

  test "the refusal wording follows the map too" do
    staff = Staff.create!(user_id: "UFF9", community_manager: false)
    Fd::AccessGrant.give!("UFF9", role: "firefighter", by: "UME")
    move("firefighter", "case.reverse", false)

    assert_equal "reverse an action somebody logged is lead only",
      Fd::Access.why_not(Staff.find("UFF9"), "case.reverse")
  end
end
