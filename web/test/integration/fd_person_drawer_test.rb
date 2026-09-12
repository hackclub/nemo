require "test_helper"

class FdPersonDrawerTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def get_drawer(user_id)
    get fd_member_path(user_id), headers: { "Turbo-Frame" => "person-drawer" }
  end

  test "the drawer answers inside its own frame" do
    get_drawer "UNOBODY"

    assert_response :success
    assert_match "person-drawer", response.body
  end

  test "opening the drawer records the identity read against the person who opened it" do
    assert_difference -> { AccessLog.count }, 1 do
      get_drawer "USUB"
    end

    logged = AccessLog.order(:id).last
    assert_equal @me.user_id, logged.actor_id
    assert_equal "USUB", logged.subject_user_id
  end

  test "the drawer is behind case.read like the page it opens from" do
    sign_in_as(Account.create!(user_id: "UPLAIN"))

    get_drawer "USUB"

    refute_equal 200, response.status
  end
end
