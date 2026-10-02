require "test_helper"

class FdCaseIndexTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def told(kase, **attrs)
    Fd::CaseReport.create!({ case_id: kase.id, reporter_user_id: "UREP", is_anonymous: false,
      source_app: "shroud", received_at: 3.days.ago }.merge(attrs))
  end

  test "the index lists the open cases in the pane" do
    kase = make_case
    told kase

    get fd_cases_path

    assert_response :success
    assert_select "section.pane .qrow"
    assert_match kase.id.to_s, response.body
  end

  test "a layout parameter buys nothing" do
    told make_case
    told make_case

    get fd_cases_path
    assert_response :success
    plain = response.body

    get fd_cases_path(layout: "board")
    assert_response :success
    assert_equal plain.scan(%r{/fd/cases/(\d+)}).flatten.uniq,
      response.body.scan(%r{/fd/cases/(\d+)}).flatten.uniq

    get fd_cases_path(layout: "table")
    assert_response :success
    assert_select "table.queue-table", false
  end

  test "the index is behind case.read" do
    sign_in_as(Account.create!(user_id: "UPLAIN"))

    get fd_cases_path

    refute_equal 200, response.status
  end
end
