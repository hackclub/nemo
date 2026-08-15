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
    get fd_cases_path(view: "mine")

    assert listed?(@mine)
    assert_not listed?(@theirs), "somebody else's case is not mine"
    assert_not listed?(@free), "an unassigned case is not mine either"
  end

  test "a case I share with somebody else is still mine" do
    @mine.assign!("UOTHER")
    @mine.assign!("UME")
    get fd_cases_path(view: "mine")

    assert listed?(@mine)
  end

  test "the mine filter drops a case once I step off it" do
    @mine.assign!("UME")
    @mine.assignees.sole.destroy!
    get fd_cases_path(view: "mine")

    assert_not listed?(@mine)
  end

  test "a resolved case of mine is not in the open queue" do
    @mine.assign!("UME")
    @mine.update!(resolved_at: 1.hour.ago, resolution: "no_action")
    get fd_cases_path(view: "mine")

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

  test "the open queue names everybody a case is on, each copyable" do
    @mine.assign!("UONE")
    @mine.assign!("UTWO")
    get fd_cases_path

    assert_select "button.handle[data-copy-id-value=UONE]", text: "@UONE"
    assert_select "button.handle[data-copy-id-value=UTWO]", text: "@UTWO"
  end

  test "the six views are offered, with the current one marked" do
    get fd_cases_path

    assert_select ".views .view", 6
    assert_select ".view[aria-current]", text: /Needs attention/
  end

  test "a view carries a count you can read before clicking it" do
    get fd_cases_path(view: "unassigned")

    assert_select ".view[aria-current]", text: /Unassigned/
    assert_select ".view", text: /Unassigned #{Fd::Case.unresolved.unassigned.count}/
  end

  test "needs attention keeps a fresh claimed case as well as a free one" do
    fresh_free = make_case(opened_at: 1.hour.ago)
    fresh_taken = make_case(opened_at: 1.hour.ago, assign: "UOTHER")
    resolved = make_case(opened_at: 1.hour.ago, resolved_at: Time.current, resolution: "no_action")
    get fd_cases_path

    assert listed?(fresh_free), "nobody is on it"
    assert listed?(fresh_taken), "somebody is on it, but it is still open"
    assert_not listed?(resolved), "resolved cases stay off the queue"
  end

  test "choosing a view sets the facets it implies" do
    get fd_cases_path(view: "mine")

    assert_select ".facet-set.on .facet", text: /Assignee\s*me/
    assert_select ".facet-set.on .facet", text: /Status\s*open/
  end

  test "changing a facet turns the view off and keeps what the view had set" do
    @mine.assign!("UME")
    @mine.update!(category_key: "spam")
    @theirs.assign!("UME")

    get fd_cases_path(status: "open", assignee: "me", category: "spam")

    assert listed?(@mine)
    assert_not listed?(@theirs), "the category still narrows it"
    assert_select ".view[aria-current]", 0, "no view is in force once you filter"
  end

  test "clearing the last facet of a view does not fall back into that view" do
    get fd_cases_path(view: "none")

    assert_select ".view[aria-current]", 0
    assert_select ".card-title", text: "Every case"
  end

  test "an unassigned row offers the claim button, an assigned one does not" do
    @mine.assign!("UME")
    get fd_cases_path

    assert_select "form[action=?] button", fd_case_claim_path(@free), text: "Claim"
    assert_select "form[action=?] button", fd_case_claim_path(@mine), count: 0
  end
end
