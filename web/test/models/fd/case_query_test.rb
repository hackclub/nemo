require "test_helper"

class Fd::CaseQueryTest < ActiveSupport::TestCase
  setup do
    @fresh = make_case(opened_at: 1.hour.ago)
    @stale = make_case(opened_at: 6.days.ago)
    @taken = make_case(opened_at: 1.hour.ago, assign: "UME")
    @done = make_case(opened_at: 20.days.ago, resolved_at: 1.day.ago, resolution: "no_action")
  end

  def query(viewer: "UME", **params)
    Fd::CaseQuery.new(params.stringify_keys, viewer: viewer)
  end

  def ids(viewer: "UME", **params)
    mine = [@fresh, @stale, @taken, @done].map(&:id)
    query(viewer: viewer, **params).relation.where(id: mine).ids
  end

  test "an empty request lands on the open cases" do
    assert_equal "attention", query.view
  end

  test "a value outside the vocabulary is ignored, not raised" do
    assert_equal "attention", query(view: "; drop table").view
    assert_equal "any", query(age: "300d")["age"]
    assert_equal "opened", query(sort: "sideways")["sort"]
    assert_equal "anyone", query(assignee: "not a user id")["assignee"]
  end

  test "a member id is accepted for assignee and subject, anything else is not" do
    assert_equal "U08K3F2QX", query(assignee: "U08K3F2QX")["assignee"]
    assert_equal "anyone", query(subject: "bob")["subject"]
  end

  test "needs attention keeps every open case, claimed or not" do
    found = ids
    assert_includes found, @fresh.id, "unassigned"
    assert_includes found, @stale.id, "six days old"
    assert_includes found, @taken.id, "somebody is on it, but it is still open"
    assert_not_includes found, @done.id, "resolved, so it is off the queue"
  end

  test "aging only keeps what has sat past five days" do
    found = ids(view: "aging")
    assert_equal [@stale.id], found
  end

  test "mine follows the viewer, and is empty for somebody else" do
    assert_equal [@taken.id], ids(view: "mine")
    assert_empty ids(view: "mine", viewer: "USOMEBODY")
  end

  test "resolved this month reads resolved_at, not opened_at" do
    assert_equal [@done.id], ids(view: "resolved"),
      "the case was opened twenty days ago and closed yesterday"
  end

  test "everything is everything" do
    assert_equal 4, ids(view: "everything").size
  end

  test "a facet turns the view off, they are never both in force" do
    both = query(view: "mine", category: "spam")
    assert_nil both.view, "filtering wins, so no view is current"
    assert_equal "spam", both["category"]
    assert_equal "any", both["status"], "the view's implied status goes with it"
  end

  test "a view sets the facets it implies, so the pills agree with the tab" do
    mine = query(view: "mine")
    assert_equal "me", mine["assignee"]
    assert_equal "open", mine["status"]
    assert mine.facets.find { |f| f.key == "assignee" }.on
  end

  test "changing a facet from inside a view expands that view into plain filters" do
    from_mine = query(view: "mine").facet_params("category" => "spam")

    assert_equal({ "status" => "open", "assignee" => "me", "category" => "spam" }, from_mine)
    assert_not from_mine.key?("view"), "the link must not carry the view it just left"
  end

  test "the title names the view, or reads as a sentence once filtering takes over" do
    assert_equal "Mine", query(view: "mine").title
    assert_equal "Every case, spam", query(category: "spam").title
    assert_equal "Open, older than five days and unassigned",
      query(status: "open", age: "5d", assignee: "nobody").title
  end

  test "the url carries the view or the facets, never both" do
    assert_empty query.to_params
    assert_equal({ "view" => "mine" }, query(view: "mine").to_params)
    assert_equal({ "category" => "spam" }, query(category: "spam", age: "any").to_params)
  end

  test "clearing the last facet a view implied leaves the view rather than landing back in it" do
    leaving = query(view: "attention").facet_params("status" => "any")
    assert_equal({ "view" => "none" }, leaving,
      "an empty link would be read as a bare queue, which defaults straight back to a view")

    landed = query(view: "none")
    assert_nil landed.view
    assert_equal "Every case", landed.title
    assert_equal 4, ids(view: "none").size
  end

  test "the status facet can override the view, since a view is not a status" do
    assert_equal [@done.id], ids(view: "everything", status: "resolved")
  end

  test "only the four primary facets sit inline until one of the others is set" do
    bare = query(view: "none")
    assert_equal %w[status age assignee sort], bare.inline_facets.map(&:key)
    assert_equal %w[category subject actions opened resolved], bare.more_facets.map(&:key)

    narrowed = query(category: "spam")
    assert_equal %w[category status age assignee sort], narrowed.inline_facets.map(&:key)
    assert_equal %w[subject actions opened resolved], narrowed.more_facets.map(&:key)
  end

  test "every view reports a count" do
    counts = Fd::CaseQuery.view_counts("UME")
    assert_equal Fd::CaseQuery::VIEWS.keys.sort, counts.keys.sort
    assert counts.values.all? { |n| n.is_a?(Integer) }
  end

  def counted_one_by_one(viewer)
    Fd::CaseQuery::VIEWS.keys.index_with do |key|
      Fd::CaseQuery.new(ActionController::Parameters.new("view" => key), viewer: viewer)
        .relation.count
    end
  end

  test "the one counting query agrees with running each view on its own" do
    make_case(opened_at: 9.days.ago)
    make_case(opened_at: 1.hour.ago, assign: "UME")
    make_case(opened_at: 2.hours.ago, assign: "UOTHER")
    make_case(opened_at: 3.days.ago, resolved_at: Time.current, resolution: "no_action")

    assert_equal counted_one_by_one("UME"), Fd::CaseQuery.view_counts("UME")
  end

  test "the counts still agree when nobody is signed in" do
    make_case(opened_at: 1.hour.ago, assign: "UOTHER")

    assert_equal counted_one_by_one(nil), Fd::CaseQuery.view_counts(nil)
  end

  def act_on(kase, category:, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: "USUB",
                         decided_by: "UFF1", performed_by: "UFF1", reason: "why",
                         category_key: category }.merge(attrs))
  end

  test "a case with actions is about what its actions say" do
    kase = make_case(category_key: "spam")
    act_on(kase, category: "harassment_general")

    assert_equal ["harassment_general"], kase.reload.violations,
      "the action is what was actually decided"
  end

  test "a case names every violation its actions name" do
    kase = make_case(category_key: "spam")
    act_on(kase, category: "harassment_general")
    act_on(kase, category: "adult")

    assert_equal %w[harassment_general adult].sort, kase.reload.violations.sort,
      "two actions can be about two different things"
  end

  test "a reversed action no longer says what the case was about" do
    kase = make_case(category_key: "spam")
    act_on(kase, category: "harassment_general", reversed_at: Time.current, reversed_by: "UME")

    assert_equal ["spam"], kase.reload.violations
  end

  test "a case with no actions falls back to its own violation" do
    kase = make_case(category_key: "spam")

    assert_equal ["spam"], kase.violations
  end

  def found_under(category)
    query(view: "everything", category: category).relation.ids
  end

  test "filtering by violation finds the case its actions name, not its own" do
    kase = make_case(category_key: "spam")
    act_on(kase, category: "harassment_general")

    assert_includes found_under("harassment_general"), kase.id,
      "the filter must find what the queue shows"
    assert_not_includes found_under("spam"), kase.id,
      "the case column no longer speaks once an action has"
  end

  test "filtering still finds a case that has no actions" do
    kase = make_case(category_key: "spam")

    assert_includes found_under("spam"), kase.id
  end

  test "the batch lookup agrees with the one built per case" do
    first = make_case(category_key: "spam")
    act_on(first, category: "adult")
    second = make_case(category_key: "spam")

    batch = Fd::Case.violations_for([first.id, second.id])

    assert_equal ["adult"], batch[first.id]
    assert_nil batch[second.id], "a case with no acted violation is absent, not empty"
    assert_equal ["spam"], second.violations
  end

  test "the queue opens with the oldest case first" do
    assert_equal [@stale.id, @fresh.id, @taken.id], ids(view: "everything") - [@done.id],
      "the case that has waited longest is the one that needs somebody"
  end

  test "asking for the newest first still works" do
    oldest_first = ids(view: "everything")

    assert_equal oldest_first.reverse, ids(view: "everything", dir: "desc")
  end

  test "sorting a column starts in the default direction, then reverses, then clears" do
    bare = query.sort_params("case")
    assert_equal "case", bare["sort"]
    assert_not_includes bare.keys, "dir",
      "a fresh column starts in the default direction, so dir stays out of the url"

    ascending = query(sort: "case")
    assert_equal "desc", ascending.sort_params("case")["dir"], "clicking again reverses it"

    descending = query(sort: "case", dir: "desc")
    assert_not_includes descending.sort_params("case").keys, "sort",
      "a third click drops back to the default sort"
  end
end
