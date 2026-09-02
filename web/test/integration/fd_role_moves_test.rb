require "test_helper"

class FdRoleMovesTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def move(role, key, allowed)
    patch fd_role_permission_path, params: { role: role, key: key, allowed: allowed }
  end

  def switch_for(key, role)
    at = Authz.grantable_roles.reject { |name| Authz.superadmin?(name) }.index(role)
    row = css_select("tr").find { |tr| tr.css("td.mono").text.include?(key) }
    row&.css("td.col-num")&.[](at)&.css("button, span")&.first
  end

  test "the roles table offers a switch to a manager, and nobody else gets in" do
    get admin_roles_path
    assert_equal "button", switch_for("decision.settle", "firefighter").name

    drop_roles!("UME")
    hold_role!("UME", "firefighter")

    get admin_roles_path
    assert_redirected_to root_path, "the admin section is managers only"
  end

  test "moving a permission changes what the table says and what is enforced" do
    move("firefighter", "decision.settle", "1")

    assert_redirected_to admin_roles_path
    follow_redirect!
    assert_equal "on", switch_for("decision.settle", "firefighter").text.strip
    assert_includes Authz.baseline("firefighter"), "decision.settle"
  end

  test "a moved key is marked, and unmarked when it goes back" do
    move("firefighter", "decision.settle", "0")
    get admin_roles_path
    assert_select ".chip-crit", text: /taken from firefighter/

    move("firefighter", "decision.settle", "1")
    get admin_roles_path
    assert_select ".chip-crit", text: /taken from firefighter/, count: 0
  end

  test "every move is written to the audit with the pair it changed" do
    move("firefighter", "case.reverse", "0")

    entry = Fd::AuditEntry.where(entity_type: "permission").recent_first.first
    assert_equal ["revoked", "UME"], [entry.verb, entry.actor_user_id]
    assert_equal "firefighter/case.reverse", entry.entity_ref
    assert_equal({ "permission" => "case.reverse", "role" => "firefighter",
                   "allowed" => false }, entry.after)
  end

  test "access.grant has no switch at all" do
    get admin_roles_path

    assert_equal "span", switch_for("access.grant", "firefighter").name
    move("firefighter", "access.grant", "1")
    assert_equal "access.grant cannot be moved", flash[:alert]
  end

  test "a manager keeps a capability even after every other role loses it" do
    move("firefighter", "decision.settle", "0")

    assert_nil flash[:alert]
    refute Authz.holds?(hold_role!("UFFONLY", "firefighter"), "decision.settle")
    assert Authz.holds?(@me, "decision.settle"), "a manager holds everything"
  end

  test "the superadmin role has nothing to move" do
    move("community_manager", "decision.settle", "0")

    assert_equal "community_manager holds everything already", flash[:alert]
  end

  test "a firefighter cannot move anything" do
    drop_roles!("UME")
    hold_role!("UME", "firefighter")

    move("firefighter", "case.reverse", "0")

    assert_empty Authz::Override.all
    assert_equal 1, Fd::AuditEntry.where(verb: "refused", actor_user_id: "UME").count
  end

  test "the move shows up in what that manager did" do
    move("firefighter", "case.reverse", "0")

    get admin_person_path("UME", did: "access.grant")

    assert_select "table.data-table", text: /Took from a role/m
  end
end
