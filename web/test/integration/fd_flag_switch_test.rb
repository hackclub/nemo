require "test_helper"

class FdFlagSwitchTest < ActionDispatch::IntegrationTest
  setup do
    @boss = Staff.create!(user_id: "UBOSS", community_manager: true)
    Fd::Flag.delete_all
    Current.forget_flags
  end

  teardown do
    Fd::Flag.delete_all
    Current.forget_flags
  end

  test "one table names every section by the routes that stop resolving" do
    sign_in_as(@boss)
    get admin_flags_path

    assert_response :success
    assert_select "td b", text: "Community analytics"
    assert_select "td.said-cell .mono", text: "/channels"
    assert_select "form[action=?]", fd_flag_path(key: "analytics", on: "0")
  end

  test "a dark section sorts to the top of the table" do
    sign_in_as(@boss)
    Fd::Flag.set!("fire_engine", false, by: @boss.user_id)

    get admin_flags_path

    assert_select "tbody tr:first-child td b", text: "Fire Engine"
  end

  def standing(key)
    Fd::Flag.find_by(key: key.to_s)&.is_on
  end

  test "a manager can turn one off and back on from the page" do
    sign_in_as(@boss)

    patch fd_flag_path, params: { key: "decisions", on: "0" }
    assert_redirected_to admin_flags_path
    assert_match(/decisions is turned off/, flash[:notice])
    assert_equal false, standing(:decisions)

    patch fd_flag_path, params: { key: "decisions", on: "1" }
    assert_match(/decisions is back/, flash[:notice])
    assert_equal true, standing(:decisions)
    assert_equal 1, Fd::Flag.where(key: "decisions").count, "one row, flipped"
  end

  test "a firefighter cannot flip anything" do
    hand = Staff.create!(user_id: "UHAND")
    Fd::AccessGrant.give!("UHAND", role: "firefighter", by: @boss.user_id, reason: "works here")
    sign_in_as(hand)

    patch fd_flag_path, params: { key: "analytics", on: "0" }

    assert_nil standing(:analytics), "nothing was written"
    assert_not_nil flash[:alert]
  end

  test "a flip is written to the trail" do
    sign_in_as(@boss)

    patch fd_flag_path, params: { key: "analytics", on: "0" }

    said = Fd::AuditEntry.where(verb: "turned_off").last
    assert_equal "UBOSS", said.actor_user_id
    assert_equal "analytics", said.after["flag"]
  end

  test "a section the file does not know is refused" do
    sign_in_as(@boss)

    patch fd_flag_path, params: { key: "teleporter", on: "0" }

    assert_redirected_to admin_flags_path
    assert_match(/not a flag/, flash[:alert])
  end
end
