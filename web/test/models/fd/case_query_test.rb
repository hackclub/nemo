require "test_helper"

class Fd::CaseQueryTest < ActiveSupport::TestCase
  setup do
    @recent = make_case(opened_at: 1.hour.ago)
    @stale = make_case(opened_at: 6.days.ago)
    @assigned = make_case(opened_at: 1.hour.ago, assign: "UME")
    @done = make_case(opened_at: 20.days.ago, resolved_at: 1.day.ago, resolution: "no_action")
  end

  def query(viewer: "UME", **params)
    Fd::CaseQuery.new(params.stringify_keys, viewer: viewer)
  end

  def ids(viewer: "UME", **params)
    case_ids = [@recent, @stale, @assigned, @done].map(&:id)
    query(viewer: viewer, **params).relation.where(id: case_ids).ids
  end

  test "view defaults to attention without params" do
    assert_equal "attention", query.view
  end

  test "unknown param values fall back to defaults and do not raise" do
    assert_equal "attention", query(view: "; drop table").view
    assert_equal "any", query(age: "300d")["age"]
    assert_equal "opened", query(sort: "sideways")["sort"]
    assert_equal "anyone", query(assignee: "not a user id")["assignee"]
  end

  test "assignee accepts a member id and subject rejects a non id value" do
    assert_equal "U08K3F2QX", query(assignee: "U08K3F2QX")["assignee"]
    assert_equal "anyone", query(subject: "bob")["subject"]
  end

  test "attention view includes every open case assigned or not" do
    listed_ids = ids
    assert_includes listed_ids, @recent.id, "unassigned"
    assert_includes listed_ids, @stale.id, "six days old"
    assert_includes listed_ids, @assigned.id, "assigned and open"
    assert_not_includes listed_ids, @done.id, "resolved"
  end

  test "aging view includes only cases older than five days" do
    listed_ids = ids(view: "aging")
    assert_equal [@stale.id], listed_ids
  end

  test "mine view lists the viewer's cases and none for another viewer" do
    assert_equal [@assigned.id], ids(view: "mine")
    assert_empty ids(view: "mine", viewer: "USOMEBODY")
  end

  test "resolved view filters by resolved_at and not opened_at" do
    assert_equal [@done.id], ids(view: "resolved"),
      "resolved case missing from resolved view"
  end

  test "everything view includes all cases" do
    assert_equal 4, ids(view: "everything").size
  end

  test "facet param clears the view and resets status to any" do
    filtered_query = query(view: "mine", category: "spam")
    assert_nil filtered_query.view, "view set while a facet is applied"
    assert_equal "spam", filtered_query["category"]
    assert_equal "any", filtered_query["status"], "status not reset to any when the view is cleared"
  end

  test "mine view sets assignee me and status open and marks assignee on" do
    mine_view_query = query(view: "mine")
    assert_equal "me", mine_view_query["assignee"]
    assert_equal "open", mine_view_query["status"]
    assert mine_view_query.facets.find { |f| f.key == "assignee" }.on
  end

  test "facet_params expands the view into status and assignee params" do
    expanded_params = query(view: "mine").facet_params("category" => "spam")

    assert_equal({ "status" => "open", "assignee" => "me", "category" => "spam" }, expanded_params)
    assert_not expanded_params.key?("view"), "view key present in facet_params"
  end

  test "title uses the view name or a sentence built from the facets" do
    assert_equal "Mine", query(view: "mine").title
    assert_equal "All cases, spam, mass pings or invites", query(category: "spam").title
    assert_equal "Open, older than five days and unassigned",
      query(status: "open", age: "5d", assignee: "nobody").title
  end

  test "to_params returns either the view or the facets" do
    assert_empty query.to_params
    assert_equal({ "view" => "mine" }, query(view: "mine").to_params)
    assert_equal({ "category" => "spam" }, query(category: "spam", age: "any").to_params)
  end

  test "facet_params clearing the last implied facet returns view none" do
    facet_params = query(view: "attention").facet_params("status" => "any")
    assert_equal({ "view" => "none" }, facet_params,
      "empty params would fall back to the default view")

    none_query = query(view: "none")
    assert_nil none_query.view
    assert_equal "All cases", none_query.title
    assert_equal 4, ids(view: "none").size
  end

  test "status param overrides the status implied by the everything view" do
    assert_equal [@done.id], ids(view: "everything", status: "resolved")
  end

  test "inline_facets lists four primary facets until another facet is set" do
    bare = query(view: "none")
    assert_equal %w[status age assignee sort], bare.inline_facets.map(&:key)
    assert_equal %w[category subject actions opened resolved], bare.more_facets.map(&:key)

    filtered_query = query(category: "spam")
    assert_equal %w[category status age assignee sort], filtered_query.inline_facets.map(&:key)
    assert_equal %w[subject actions opened resolved], filtered_query.more_facets.map(&:key)
  end

  test "view_counts returns an integer for every view" do
    counts = Fd::CaseQuery.view_counts("UME")
    assert_equal Fd::CaseQuery::VIEWS.keys.sort, counts.keys.sort
    assert counts.values.all? { |n| n.is_a?(Integer) }
  end

  def counts_per_view(viewer)
    Fd::CaseQuery::VIEWS.keys.index_with do |key|
      Fd::CaseQuery.new(ActionController::Parameters.new("view" => key), viewer: viewer)
        .relation.count
    end
  end

  test "view_counts matches the relation count of each view" do
    make_case(opened_at: 9.days.ago)
    make_case(opened_at: 1.hour.ago, assign: "UME")
    make_case(opened_at: 2.hours.ago, assign: "UOTHER")
    make_case(opened_at: 3.days.ago, resolved_at: Time.current, resolution: "no_action")

    assert_equal counts_per_view("UME"), Fd::CaseQuery.view_counts("UME")
  end

  test "view_counts matches the relation count of each view for a nil viewer" do
    make_case(opened_at: 1.hour.ago, assign: "UOTHER")

    assert_equal counts_per_view(nil), Fd::CaseQuery.view_counts(nil)
  end

  def act_on(kase, category:, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: "USUB",
                         decided_by: "UFF1", performed_by: "UFF1", reason: "why",
                         category_key: category }.merge(attrs))
  end

  test "violations uses the action category when the case has actions" do
    kase = make_case(category_key: "spam")
    act_on(kase, category: "harassment_general")

    assert_equal ["harassment_general"], kase.reload.violations,
      "violations did not use the action category"
  end

  test "violations lists the category of every action" do
    kase = make_case(category_key: "spam")
    act_on(kase, category: "harassment_general")
    act_on(kase, category: "adult")

    assert_equal %w[harassment_general adult].sort, kase.reload.violations.sort,
      "violations missing a category of one action"
  end

  test "violations ignores reversed actions" do
    kase = make_case(category_key: "spam")
    act_on(kase, category: "harassment_general", reversed_at: Time.current, reversed_by: "UME")

    assert_equal ["spam"], kase.reload.violations
  end

  test "violations falls back to category_key when the case has no actions" do
    kase = make_case(category_key: "spam")

    assert_equal ["spam"], kase.violations
  end

  def ids_in_category(category)
    query(view: "everything", category: category).relation.ids
  end

  test "category filter matches action categories and not the case category_key" do
    kase = make_case(category_key: "spam")
    act_on(kase, category: "harassment_general")

    assert_includes ids_in_category("harassment_general"), kase.id,
      "category filter missed the case with a matching action category"
    assert_not_includes ids_in_category("spam"), kase.id,
      "category filter matched the case category_key"
  end

  test "category filter matches category_key when the case has no actions" do
    kase = make_case(category_key: "spam")

    assert_includes ids_in_category("spam"), kase.id
  end

  test "violations_for matches violations per case" do
    first = make_case(category_key: "spam")
    act_on(first, category: "adult")
    second = make_case(category_key: "spam")

    batch = Fd::Case.violations_for([first.id, second.id])

    assert_equal ["adult"], batch[first.id]
    assert_nil batch[second.id], "a case with no acted violation is absent, not empty"
    assert_equal ["spam"], second.violations
  end

  test "everything view orders cases newest opened first" do
    assert_equal [@assigned.id, @recent.id, @stale.id], ids(view: "everything") - [@done.id],
      "everything view is not ordered newest first"
  end

  test "resolved view orders cases by resolved_at descending" do
    older = make_case(opened_at: 30.days.ago, resolved_at: 9.days.ago, resolution: "no_action")
    newer = make_case(opened_at: 2.days.ago, resolved_at: 1.hour.ago, resolution: "no_action")
    resolved_ids = query(view: "resolved").relation.where(id: [older.id, newer.id, @done.id]).ids

    assert_equal [newer.id, @done.id, older.id], resolved_ids,
      "resolved view is not ordered newest resolved first"
    assert_equal "resolved", query(view: "resolved")["sort"]
    assert_equal "desc", query(view: "resolved")["dir"]
  end

  test "dir asc reverses the everything view order" do
    newest_first = ids(view: "everything")

    assert_equal newest_first.reverse, ids(view: "everything", dir: "asc")
  end

  test "dir asc keeps the view and its filter" do
    oldest = query(view: "unassigned", dir: "asc")

    assert_equal "unassigned", oldest.view
    assert_equal({ "view" => "unassigned", "dir" => "asc" }, oldest.to_params)
    assert_equal [@stale.id, @recent.id], ids(view: "unassigned", dir: "asc")
  end

  test "reordered_params drops dir for the default order" do
    assert_equal({ "dir" => "asc" }, query.reordered_params("asc"))
    assert_empty query(dir: "asc").reordered_params("desc")
    assert_equal({ "view" => "none", "dir" => "asc" }, query(view: "none").reordered_params("asc"))
    assert_equal({ "category" => "spam" }, query(category: "spam", dir: "asc").reordered_params("desc"))
  end

  test "sort_params keeps the default direction then reverses then drops sort" do
    bare = query.sort_params("case")
    assert_equal "case", bare["sort"]
    assert_not_includes bare.keys, "dir",
      "dir present for a fresh column"

    ascending = query(sort: "case")
    assert_equal "asc", ascending.sort_params("case")["dir"], "dir not asc for the second click"

    reversed = query(sort: "case", dir: "asc")
    assert_not_includes reversed.sort_params("case").keys, "sort",
      "sort present for the third click"
  end
end
