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

  test "the board lays the open cases out as cards" do
    kase = make_case
    told kase

    board

    assert_select ".rep-feed"
    assert_match kase.id.to_s, response.body
  end

  test "the board and the queue answer over the same cases" do
    told make_case
    told make_case

    board
    carded = response.body.scan(%r{/fd/cases/(\d+)}).flatten.uniq

    get fd_cases_path
    assert_response :success
    queued = response.body.scan(%r{/fd/cases/(\d+)}).flatten.uniq

    assert_equal 2, carded.size, "the board drew no cases, so this compares nothing"
    assert_equal queued.sort, carded.sort
  end

  test "the board is behind case.read" do
    sign_in_as(Account.create!(user_id: "UPLAIN"))

    get fd_cases_path(layout: "board")

    refute_equal 200, response.status
  end
end
