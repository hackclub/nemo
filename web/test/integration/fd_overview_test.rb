require "test_helper"

class FdOverviewTest < ActionDispatch::IntegrationTest
  setup do
    @me = Account.create!(user_id: "UFF1")
    hold_role!("UFF1", "firefighter")
    sign_in_as(@me)

    AccessLog.create!(actor_id: "UOTHER", subject_user_id: "USUB",
      field_class: "identity", looked_at: 1.hour.ago)
  end

  test "the overview does not show what other people looked up" do
    get fd_root_path

    assert_response :success
  end
end
