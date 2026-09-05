require "test_helper"

class FdBoardTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def told(kase, **attrs)
    Fd::CaseReport.create!({ case_id: kase.id, reporter_user_id: "UREP", is_anonymous: false,
      source_app: "shroud", received_at: 3.days.ago }.merge(attrs))
  end

  def board(**params)
    get fd_cases_path(params.merge(layout: "board"))
    assert_response :success
  end
end
