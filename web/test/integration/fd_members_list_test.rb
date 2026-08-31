require "test_helper"

class FdMembersListTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def listed?(user_id)
    css_select("a[href='#{fd_member_path(user_id)}']").any?
  end

  def listed_links
    css_select("tbody tr .row-name a").map { |link| link["href"] }
  end

  def act_on(kase, target:, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: target,
                         decided_by: "UFF1", performed_by: "UFF1" }.merge(attrs))
  end

  test "a signed out visitor cannot see the list" do
    delete logout_path
    get fd_members_path
    assert_redirected_to login_path
  end

  test "landing on the list picks a view rather than leaving none chosen" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path

    assert_equal "everyone", Fd::MemberQuery.new({}).view
    assert_select ".view[aria-current]", 1
    assert listed?("UHASONE")
  end

  test "the history view narrows to people conduct work has touched" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path(view: "history")

    assert listed?("UHASONE")
    assert_not listed?(Fd::Member.live.where.not(user_id: "UHASONE").first.user_id),
      "nine thousand quiet members are not the working set"
  end

  test "somebody only ever logged in another case still belongs here" do
    theirs = make_case(subject: "USOMEBODY", opened_at: 3.days.ago)
    theirs.participants.create!(user_id: "UWATCHER", role: "involved", detail: "aimed at them")

    get fd_members_path

    assert listed?("UWATCHER"), "a page of subjects would hide the people conduct work is for"
    assert_select "td.col-num", text: "0", minimum: 1
  end

  def numbers_for(user_id)
    row = css_select("tr").find { |tr| tr.to_s.include?(user_id) }
    row.css("td.col-cases, td.col-actions").map(&:text).map(&:strip)
  end

  test "a row counts every case that named them, and the actions apart" do
    make_case(subject: "UBOTH", opened_at: 5.days.ago)
    theirs = make_case(subject: "USOMEBODY", opened_at: 3.days.ago)
    theirs.participants.create!(user_id: "UBOTH", role: "reporter")

    get fd_members_path(view: "history")

    assert_equal %w[2 0], numbers_for("UBOTH"),
      "subject of one and logged in another is two cases, no actions"
  end

  test "one case that names somebody twice is still one case" do
    both = make_case(subject: "UTWICE", opened_at: 5.days.ago)
    both.participants.create!(user_id: "UTWICE", role: "reporter")

    get fd_members_path(view: "history")

    assert_equal %w[1 0], numbers_for("UTWICE"),
      "reporting the case you are the subject of does not make it two cases"
  end

  test "only the named tabs are offered, with counts, the current one marked" do
    get fd_members_path

    assert_select ".views .view", Fd::MemberQuery::TABS.size
    assert_select ".view[aria-current]", text: /Everyone/
    assert_select ".view .view-count", Fd::MemberQuery::TABS.size
  end

  test "the in force view keeps only people with something still running" do
    live = make_case(subject: "ULIVE", opened_at: 9.days.ago)
    act_on live, target: "ULIVE", type_key: "shush", expires_at: 5.days.from_now

    lapsed = make_case(subject: "ULAPSED", opened_at: 40.days.ago)
    act_on lapsed, target: "ULAPSED", type_key: "shush", expires_at: 1.day.ago

    warned = make_case(subject: "UWARNED", opened_at: 9.days.ago)
    act_on warned, target: "UWARNED", type_key: "warning"

    lifted = make_case(subject: "ULIFTED", opened_at: 9.days.ago)
    act_on lifted, target: "ULIFTED", type_key: "shush", expires_at: 5.days.from_now,
      reversed_at: 1.day.ago, reversed_by: "UME", reversal_reason: "appeal upheld"

    get fd_members_path(view: "force")

    assert listed?("ULIVE")
    assert_not listed?("ULAPSED"), "its due date has passed"
    assert_not listed?("UWARNED"), "a warning has no due date to reach"
    assert_not listed?("ULIFTED"), "it was reversed"
  end

  test "the open case view keeps only people with one open" do
    make_case(subject: "UOPEN", opened_at: 2.days.ago)
    make_case(subject: "UCLOSED", opened_at: 9.days.ago, resolved_at: 1.day.ago,
      resolution: "no_action")

    get fd_members_path(view: "open")

    assert listed?("UOPEN")
    assert_not listed?("UCLOSED")
  end

  test "the priors view uses the definition, not the case count" do
    acted = make_case(subject: "UPRIORS", opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "action_taken")
    act_on acted, target: "UPRIORS"
    second = make_case(subject: "UPRIORS", opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "action_taken")
    act_on second, target: "UPRIORS"

    make_case(subject: "UNOACTION", opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "no_action")
    make_case(subject: "UNOACTION", opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "no_action")

    get fd_members_path(view: "priors")

    assert listed?("UPRIORS")
    assert_not listed?("UNOACTION"), "two resolved cases with no action are not two priors"
  end

  test "a facet narrows outside the tabs, and marks none of them current" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path(priors: "2")

    assert_select ".view[aria-current]", 0
  end

  test "everyone reaches past the working set" do
    assert_operator Fd::MemberQuery.new({ "view" => "everyone" }).total, :>, 100
  end

  test "a long list is paged rather than truncated" do
    get fd_members_path(view: "everyone")

    assert_select "tbody tr", Fd::MemberQuery::LIMIT
    assert_select ".pager-at", text: /Page 1 of \d+/
    assert_select ".pager a", text: "Next"
    assert_select ".pager .is-off", text: "Back", count: 1
  end

  test "the next page shows the next slice, not the same one again" do
    get fd_members_path(view: "everyone")
    first = listed_links

    get fd_members_path(view: "everyone", page: "2")
    second = listed_links

    assert_equal Fd::MemberQuery::LIMIT, second.size
    assert_empty first & second, "page two must not repeat page one"
    assert_select ".pager-at", text: /Page 2 of/
  end

  test "a page past the end lands on the last page rather than an empty table" do
    get fd_members_path(view: "everyone", page: "99999")

    assert_select "tbody tr", minimum: 1
    assert_select ".pager .is-off", text: "Next", count: 1
  end

  test "a nonsense page number is treated as the first" do
    get fd_members_path(view: "everyone", page: "-3")
    assert_select ".pager-at", text: /Page 1 of/
  end

  test "narrowing resets to the first page" do
    get fd_members_path(view: "everyone", page: "3")
    assert_select ".pager-at", text: /Page 3 of/

    assert_not_includes Fd::MemberQuery.new({ "view" => "everyone", "page" => "3" })
      .facet_params("priors" => "2").keys, "page"
  end

  test "a short list has no pager at all" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path(priors: "2")

    assert_operator Fd::MemberQuery.new("priors" => "2").total, :<=, Fd::MemberQuery::LIMIT
    assert_select ".pager", 0
  end

  test "a view that matches nothing says which nothing it is" do
    Fd::Note.standing.update_all(deleted_at: Time.current, deleted_by: "UME")
    get fd_members_path(view: "notes")

    assert_select "tbody tr", 0
    assert_select ".empty-title", text: /No standing notes on anybody/
  end

  test "the rail offers members alongside cases, and marks which one you are on" do
    get fd_members_path
    assert_select ".rail-nav a[href=?][aria-current=page]", fd_members_path
    assert_select ".rail-nav a[href=?]:not([aria-current])", fd_cases_path

    get fd_cases_path
    assert_select ".rail-nav a[href=?][aria-current=page]", fd_cases_path
  end

  test "each row carries a face and links to the member record" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path(view: "history")

    assert_select "a[href=?]", fd_member_path("UHASONE")
    assert_select ".row-name .row-avatar", minimum: 1
  end

  test "searching narrows the roster to the people asked for" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path(q: "UHASONE")

    assert listed?("UHASONE")
    assert_select "tbody tr", 1
  end

  test "a leading at sign is ignored, so pasting a handle works" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path(q: "@uhasone")

    assert listed?("UHASONE"), "the search is case insensitive and tolerates the @"
  end

  test "a search that matches nobody says so rather than showing everybody" do
    get fd_members_path(q: "UNOSUCHPERSON")

    assert_select "tbody tr", 0
  end

  test "the search survives paging and view links" do
    query = Fd::MemberQuery.new({ "q" => "UHASONE", "view" => "everyone" })

    assert_equal "UHASONE", query.page_params(2)["q"], "paging must not drop the search"
    assert_equal "UHASONE", query.facet_params("priors" => "2")["q"],
      "narrowing must not drop the search"
  end

  test "an open case shows in the standing column" do
    make_case(subject: "UOPEN", opened_at: 2.days.ago)
    get fd_members_path

    assert_select "td .state", text: "open case"
  end
end
