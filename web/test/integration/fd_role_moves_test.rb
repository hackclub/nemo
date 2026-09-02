require "test_helper"

class FdRoleMovesTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def move(role, key, allowed)
    patch fd_role_permission_path, params: { role: role, key: key, allowed: allowed }
  end

  def switch_for(key, role)
    at = Fd::Permission::ROLES.index(role)
    row = css_select("tr").find { |tr| tr.css("td.mono").text.include?(key) }
    row&.css("td.col-num")&.[](at)&.css("button, span")&.first
  end

  test "the roles table offers a switch to a manager and a plain answer to anyone else" do
    get admin_roles_path
    assert_equal "button", switch_for("decision.settle", "firefighter").name

    move("lead", "access.read", "1")
    Staff.find("UME").update!(community_manager: false)
    Fd::AccessGrant.give!("UME", role: "lead", by: "UME")

    get admin_roles_path
    assert_response :success
    assert_equal "span", switch_for("decision.settle", "firefighter").name
  end

  test "moving a permission changes what the table says and what is enforced" do
    move("firefighter", "decision.settle", "1")

    assert_redirected_to admin_roles_path
    follow_redirect!
    assert_equal "yes", switch_for("decision.settle", "firefighter").text.strip
    assert_includes Fd::Permission.roles("decision.settle"), "firefighter"
  end

  test "a moved key is marked, and unmarked when it goes back" do
    move("firefighter", "decision.settle", "1")
    get admin_roles_path
    assert_select "td.mono", text: /decision\.settle\s+moved/

    move("firefighter", "decision.settle", "0")
    get admin_roles_path
    assert_select "td.mono", text: /decision\.settle\s+moved/, count: 0
  end

  test "every move is written to the audit with the pair it changed" do
    move("lead", "case.reverse", "0")

    entry = Fd::AuditEntry.where(entity_type: "permission").recent_first.first
    assert_equal ["revoked", "UME"], [entry.verb, entry.actor_user_id]
    assert_equal({ "permission" => "case.reverse", "role" => "lead", "allowed" => false },
      entry.after)
  end

  test "access.grant has no switch at all" do
    get admin_roles_path

    assert_equal "span", switch_for("access.grant", "community_manager").name
    move("firefighter", "access.grant", "1")
    assert_equal "access.grant cannot be moved", flash[:alert]
  end

  test "the last role holding a permission cannot be stripped of it" do
    move("firefighter", "decision.settle", "0")
    move("lead", "decision.settle", "0")
    move("community_manager", "decision.settle", "0")

    assert_equal "decision.settle would then be held by nobody", flash[:alert]
    assert_equal %w[community_manager], Fd::Permission.roles("decision.settle")
  end

  test "a firefighter cannot move anything" do
    Staff.find("UME").update!(community_manager: false)
    Fd::AccessGrant.give!("UME", role: "firefighter", by: "UME")

    move("firefighter", "decision.settle", "1")

    assert_equal Fd::Permission::LEAD, Fd::Permission.roles("decision.settle")
    assert_equal 1, Fd::AuditEntry.where(verb: "refused", actor_user_id: "UME").count
  end

  test "the move shows up in what that manager did" do
    move("lead", "case.reverse", "0")
    Fd::AccessGrant.give!("UME", role: "community_manager", by: "UME")

    get admin_person_path("UME", did: "access.grant")

    assert_select "table.data-table", text: /Took from a role/m
  end
end
