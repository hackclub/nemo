require "test_helper"

class FdQueueTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    @mine = make_case
    @theirs = make_case
    @free = make_case
    sign_in_as(@me)
  end

  def query(**asked)
    Fd::CaseQuery.new(asked.transform_keys(&:to_s), viewer: "UME")
  end

  def listed?(kase, **asked)
    query(**asked).relation.exists?(id: kase.id)
  end

  test "the mine filter lists what I am on and nothing else" do
    @mine.assign!("UME")
    @theirs.assign!("UOTHER")

    assert listed?(@mine, view: "mine")
    assert_not listed?(@theirs, view: "mine"), "somebody else's case is not mine"
    assert_not listed?(@free, view: "mine"), "an unassigned case is not mine either"
  end

  test "a case I share with somebody else is still mine" do
    @mine.assign!("UOTHER")
    @mine.assign!("UME")

    assert listed?(@mine, view: "mine")
  end

  test "the mine filter drops a case once I step off it" do
    @mine.assign!("UME")
    @mine.assignees.sole.destroy!

    assert_not listed?(@mine, view: "mine")
  end

  test "a resolved case of mine is not in the open queue" do
    @mine.assign!("UME")
    @mine.update!(resolved_at: 1.hour.ago, resolution: "no_action")

    assert_not listed?(@mine, view: "mine")
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

  test "needs attention keeps a fresh claimed case as well as a free one" do
    fresh_free = make_case(opened_at: 1.hour.ago)
    fresh_taken = make_case(opened_at: 1.hour.ago, assign: "UOTHER")
    resolved = make_case(opened_at: 1.hour.ago, resolved_at: Time.current, resolution: "no_action")

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

    asked = { status: "open", assignee: "me", category: "spam" }

    assert listed?(@mine, **asked)
    assert_not listed?(@theirs, **asked), "the category still narrows it"
    assert_nil query(**asked).view, "no view is in force once you filter"
  end

  test "clearing the last facet of a view does not fall back into that view" do
    assert_nil query(view: "none").view
    assert query(view: "none").relation.exists?
  end
end
