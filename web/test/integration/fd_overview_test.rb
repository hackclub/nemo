require "test_helper"

class FdOverviewTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UFF1")
    Fd::AccessGrant.give!("UFF1", role: "firefighter", by: "UBOSS")
    sign_in_as(@me)

    AccessLog.create!(actor_id: "UOTHER", subject_user_id: "USUB",
      field_class: "identity", looked_at: 1.hour.ago)
  end

  test "the overview does not show what other people looked up" do
    get fd_root_path

    assert_response :success
    assert_select ".card-title", { text: "Lookups", count: 0 },
      "a firefighter has no business reading everybody else's lookups from the landing page"
    assert_select "td", { text: /UOTHER/, count: 0 }
  end

  test "the overview still carries the work it is for" do
    get fd_root_path

    assert_select ".kpi-label", text: /Open cases/
  end
end
