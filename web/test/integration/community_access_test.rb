require "test_helper"

class CommunityAccessTest < ActionDispatch::IntegrationTest
  setup do
    @boss = Staff.create!(user_id: "UCABOSS", community_manager: true)
  end

  def holding_nothing
    Staff.create!(user_id: "UCANONE")
  end

  def reading(role)
    staff = Staff.create!(user_id: "UCA#{role.upcase}")
    Community::Grant.give!(staff.user_id, role: role, by: @boss.user_id)
    staff
  end

  test "somebody holding nothing lands on the front door, not a refusal" do
    sign_in_as(holding_nothing)

    get root_path

    assert_response :success
    assert_select ".card-title", text: "Open to everyone"
  end

  test "somebody holding nothing is kept out of fire engine" do
    sign_in_as(holding_nothing)

    get fd_root_path

    assert_redirected_to root_path
    assert_match(/conduct team/, flash[:alert])
  end

  test "an observer reads the workspace without any fire department grant" do
    sign_in_as(reading("observer"))

    get root_path

    assert_response :success
    assert_select ".card-title", text: "Open to everyone", count: 0,
      message: "an observer gets the real overview, not the front door"
  end

  test "an observer is kept out of the engine" do
    sign_in_as(reading("observer"))

    get engine_path

    assert_redirected_to root_path
  end

  test "a firefighter holds no community access at all" do
    hand = Staff.create!(user_id: "UCAFF")
    Fd::AccessGrant.give!(hand.user_id, role: "firefighter", by: @boss.user_id)

    assert_nil Community::Access.role(hand, "read")
    assert_nil Community::Access.role(hand, "ops")
    assert_not Community::Access.allow?(hand, "analytics.workspace.read")
  end

  test "a community manager holds the top of both ladders without a grant" do
    assert_equal "curator", Community::Access.role(@boss, "read")
    assert_equal "steward", Community::Access.role(@boss, "ops")
    assert Community::Access.allow?(@boss, "ops.engine.sync")
    assert_equal 0, Community::Grant.where(user_id: @boss.user_id).count,
      "the manager is superadmin by role, not by a grant row"
  end

  test "the two ladders are held independently" do
    staff = Staff.create!(user_id: "UCABOTH")
    Community::Grant.give!(staff.user_id, role: "observer", by: @boss.user_id)
    Community::Grant.give!(staff.user_id, role: "steward", by: @boss.user_id)

    assert_equal "observer", Community::Access.role(staff, "read")
    assert_equal "steward", Community::Access.role(staff, "ops")
    assert_not Community::Access.allow?(staff, "analytics.member.read")
    assert Community::Access.allow?(staff, "ops.engine.sync")
  end

  test "a new grant in one family retires only that family" do
    staff = Staff.create!(user_id: "UCASWAP")
    Community::Grant.give!(staff.user_id, role: "observer", by: @boss.user_id)
    Community::Grant.give!(staff.user_id, role: "operator", by: @boss.user_id)
    Community::Grant.give!(staff.user_id, role: "analyst", by: @boss.user_id)

    assert_equal "analyst", Community::Access.role(staff, "read")
    assert_equal "operator", Community::Access.role(staff, "ops"),
      "granting a read role must not disturb the ops ladder"
    assert_equal 2, Community::Grant.live.where(user_id: staff.user_id).count
  end
end
