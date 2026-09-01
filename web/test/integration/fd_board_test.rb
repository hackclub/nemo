require "test_helper"

class FdBoardTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
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

  test "the board prints the whole report, not an excerpt" do
    said = "They keep bringing it up after I asked them to stop. " \
      "I have screenshots of the last three times, and two other people saw it happen."
    told(make_case, body: said)
    board

    assert_includes response.body, said
  end

  test "the board names the reporter" do
    told(make_case, reporter_user_id: "UREP1")
    board

    assert_select ".rep-name", text: "@UREP1"
  end

  test "an anonymous report withholds the reporter" do
    told(make_case, reporter_user_id: nil, is_anonymous: true, body: "please look at this")
    board

    assert_select ".rep-anon", text: "anonymous"
    assert_select ".rep-name", false, "an anonymous reporter is never named"
  end

  test "a case opened by staff says so instead of showing a blank" do
    make_case
    board

    assert_select ".rep-anon", text: "no report on file"
  end

  test "both reports on a case are shown" do
    kase = make_case
    told(kase, reporter_user_id: "UREP1", body: "first sighting")
    told(kase, reporter_user_id: "UREP2", body: "same person again")
    board

    assert_select ".rep-msg", 2
    assert_includes response.body, "first sighting"
    assert_includes response.body, "same person again"
  end

  test "an unanswered report is flagged as waiting" do
    told(make_case, body: "nobody has come back to me")
    board

    assert_select ".rep-waiting"
  end

  test "the board renders resolved cases too" do
    kase = make_case(resolved_at: 1.hour.ago, resolution: "action_taken")
    told(kase, body: "this one is finished", closed_at: 1.hour.ago, closed_by: "UME")
    board(view: "resolved")

    assert_select ".rep-card.is-resolved"
    assert_select ".rep-told"
  end

  test "the whole card opens the case" do
    kase = make_case
    told(kase, body: "look at this")
    board

    assert_select "article.rep-card[data-row-link-href-value=?]", fd_case_path(kase)
  end

  test "the layout survives a change of view" do
    make_case
    board

    assert_select "a.view[href*='layout=board']"
  end
end
