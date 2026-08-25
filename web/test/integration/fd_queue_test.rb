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

  test "filtering swaps the queue in place instead of reloading the page" do
    get fd_cases_path

    assert_select "turbo-frame#queue .views", 1, "the views and rows live in one frame"
    assert_select "turbo-frame#queue .data-table", 1
    assert_select ".views .view[data-turbo-frame=queue]", Fd::CaseQuery::TABS.size,
      "every tab stays in the frame"
    assert_select "turbo-frame#queue .kpis", 0, "the headline figures are not filtered"
  end

  test "opening a case still leaves the frame" do
    kase = make_case
    get fd_cases_path

    assert_select "a[href=?]:not([data-turbo-frame])", fd_case_path(kase)
  end

  test "every view is a tab, and one of them is always current" do
    get fd_cases_path

    assert_select ".views .view", Fd::CaseQuery::TABS.size
    assert_select ".view[aria-current]", 1
    assert_select ".view[aria-current]", text: /Open/
  end

  test "a tab carries its count and marks itself current when chosen" do
    get fd_cases_path(view: "unassigned")

    assert_select ".view[aria-current]", text: /Unclaimed/
    assert_select ".view[aria-current] .view-count",
      text: Fd::Case.unresolved.unassigned.count.to_s
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
    query = Fd::CaseQuery.new({ "view" => "mine" }, viewer: "UME")

    assert_equal "me", query["assignee"]
    assert_equal "open", query["status"]
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
    assert_select ".queue-table tbody tr", minimum: 1
  end

  test "an unassigned row offers the claim button, an assigned one does not" do
    @mine.assign!("UME")
    get fd_cases_path

    assert_select "form[action=?] button", fd_case_claim_path(@free)
    assert_select "form[action=?] button", fd_case_claim_path(@mine), count: 0
  end

  test "the whole row carries the link, not just the subject name" do
    get fd_cases_path

    assert_select "tr[data-controller=row-link][data-row-link-href-value=?]",
      fd_case_path(@free), 1
  end

  test "a row folds its category into the subtitle, with spaces not underscores" do
    @mine.update!(category_key: "harassment_general")
    get fd_cases_path

    assert_select ".two-line span", text: /harassment general/
  end

  test "a row with no category does not print a bare n/a in the subtitle" do
    get fd_cases_path

    assert_select ".two-line span", text: /\An\/a\z/, count: 0
  end
end
