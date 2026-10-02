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

  test "opening the drawer is not an identity read" do
    assert_no_difference -> { AccessLog.count } do
      get_drawer "USUB"
    end
  end

  test "the drawer is behind case.read like the page it opens from" do
    sign_in_as(Account.create!(user_id: "UPLAIN"))

    get_drawer "USUB"

    refute_equal 200, response.status
  end

  test "the drawer does not pay for the roster it never draws" do
    seen = []
    listen = ->(*, payload) { seen << payload[:sql] if payload[:sql].to_s.include?("FROM roster") }

    ActiveSupport::Notifications.subscribed(listen, "sql.active_record") { get_drawer "USUB" }

    assert_response :success
    assert_empty seen, "the drawer renders none of the roster, so it must not aggregate it"
  end

  test "the full record still draws the roster beside it" do
    seen = []
    listen = ->(*, payload) { seen << payload[:sql] if payload[:sql].to_s.include?("FROM roster") }

    ActiveSupport::Notifications.subscribed(listen, "sql.active_record") { get fd_member_path("USUB") }

    assert_response :success
    assert_not_empty seen, "the page itself shows the pane, so it still needs it"
  end
end
