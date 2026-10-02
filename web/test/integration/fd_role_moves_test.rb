require "test_helper"

class FdRoleMovesTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def move(role, key, allowed)
    patch fd_role_permission_path, params: { role: role, key: key, allowed: allowed }
  end

  test "the roles table offers a switch to a manager, and nobody else gets in" do
    get admin_roles_path

    drop_roles!("UME")
    hold_role!("UME", "firefighter")

    get admin_roles_path
    assert_redirected_to root_path, "the admin section is managers only"
  end

  test "moving a permission changes what the table says and what is enforced" do
    move("firefighter", "slack.link", "0")

    assert_redirected_to admin_roles_path
    follow_redirect!
    refute Authz::Override.find_by(role: "firefighter", capability: "slack.link").allowed
  end

  test "a moved key is marked, and unmarked when it goes back" do
    move("firefighter", "slack.link", "0")
    assert_equal false, Authz::Override.find_by(role: "firefighter", capability: "slack.link").allowed

    move("firefighter", "slack.link", "1")
    assert_equal true, Authz::Override.find_by(role: "firefighter", capability: "slack.link").allowed
  end

  test "every move is written to the audit with the pair it changed" do
    move("firefighter", "slack.link", "0")

    entry = Fd::AuditEntry.where(entity_type: "permission").recent_first.first
    assert_equal ["revoked", "UME"], [entry.verb, entry.actor_user_id]
    assert_equal "firefighter/slack.link", entry.entity_ref
    assert_equal({ "permission" => "slack.link", "role" => "firefighter",
                   "allowed" => false }, entry.after)
  end

  test "access.grant has no switch at all" do
    get admin_roles_path

    move("firefighter", "access.grant", "1")
    assert_equal "access.grant cannot be moved", flash[:alert]
  end

  test "cases and identity.read have no switch either, they are FD only" do
    get admin_roles_path

    move("firefighter", "case.read", "0")
    assert_equal "case.read cannot be moved", flash[:alert]

    move("firefighter", "identity.read", "0")
    assert_equal "identity.read cannot be moved", flash[:alert]
  end

  test "a manager keeps a capability even after every other role loses it" do
    move("firefighter", "slack.link", "0")

    assert_nil flash[:alert]
    refute Authz.holds?(hold_role!("UFFONLY", "firefighter"), "slack.link")
    assert Authz.holds?(@me, "slack.link"), "a manager holds everything"
  end

  test "the superadmin role has nothing to move" do
    move("community_manager", "slack.link", "0")

    assert_equal "community_manager holds everything already", flash[:alert]
  end

  test "a firefighter cannot move anything" do
    drop_roles!("UME")
    hold_role!("UME", "firefighter")

    move("firefighter", "case.reverse", "0")

    assert_empty Authz::Override.all
    assert_equal 1, Fd::AuditEntry.where(verb: "refused", actor_user_id: "UME").count
  end
end
