require "test_helper"

class FdQueueTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    @mine = make_case
    @theirs = make_case
    @free = make_case
    sign_in_as(@me)
  end

  def listed?(kase)
    css_select("a[href='#{fd_case_path(kase)}']").any?
  end

  test "the mine filter lists what I am on and nothing else" do
    @mine.assign!("UME")
    @theirs.assign!("UOTHER")
    get fd_cases_path(assignee: "me")

    assert listed?(@mine)
    assert_not listed?(@theirs), "somebody else's case is not mine"
    assert_not listed?(@free), "an unassigned case is not mine either"
  end

  test "a case I share with somebody else is still mine" do
    @mine.assign!("UOTHER")
    @mine.assign!("UME")
    get fd_cases_path(assignee: "me")

    assert listed?(@mine)
  end

  test "the mine filter drops a case once I step off it" do
    @mine.assign!("UME")
    @mine.assignees.sole.destroy!
    get fd_cases_path(assignee: "me")

    assert_not listed?(@mine)
  end

  test "a resolved case of mine is not in the open queue" do
    @mine.assign!("UME")
    @mine.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    get fd_cases_path(assignee: "me")

    assert_not listed?(@mine)
  end

  test "the unassigned count falls by one when a case is taken" do
    before = Fd::Case.unresolved.unassigned.count
    @free.assign!("UME")

    assert_equal before - 1, Fd::Case.unresolved.unassigned.count
  end

  test "a case on two people counts as assigned once, not twice" do
    before = Fd::Case.unresolved.unassigned.count
    @free.assign!("UME")
    @free.assign!("UOTHER")

    assert_equal before - 1, Fd::Case.unresolved.unassigned.count
  end

  test "the open queue names everybody a case is on" do
    @mine.assign!("UONE")
    @mine.assign!("UTWO")
    get fd_cases_path

    assert_match(/@UONE and @UTWO/, response.body)
  end

  test "an unassigned row offers the claim button, an assigned one does not" do
    @mine.assign!("UME")
    get fd_cases_path

    assert_select "form[action=?] button", fd_case_claim_path(@free), text: "Claim"
    assert_select "form[action=?] button", fd_case_claim_path(@mine), count: 0
  end
end
