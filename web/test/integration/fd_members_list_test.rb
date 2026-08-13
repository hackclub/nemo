require "test_helper"

class FdMembersListTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    sign_in_as(@me)
  end

  def listed?(user_id)
    css_select("a[href='#{fd_member_path(user_id)}']").any?
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

  test "the default view lists only people with a conduct history" do
    subject = make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path

    assert listed?("UHASONE")
    assert_not listed?(Fd::Member.live.where.not(user_id: "UHASONE").first.user_id),
      "nine thousand quiet members are not the working set"
    assert_equal subject.id, Fd::Case.with_subject("UHASONE").sole.id
  end

  test "somebody only ever logged in another case still belongs here" do
    theirs = make_case(subject: "USOMEBODY", opened_at: 3.days.ago)
    theirs.participants.create!(user_id: "UWATCHER", role: "involved", detail: "aimed at them")

    get fd_members_path

    assert listed?("UWATCHER"), "a page of subjects would hide the people conduct work is for"
    assert_select "td.col-num", text: "0", minimum: 1
  end

  test "subject of and logged in are counted apart" do
    make_case(subject: "UBOTH", opened_at: 5.days.ago)
    theirs = make_case(subject: "USOMEBODY", opened_at: 3.days.ago)
    theirs.participants.create!(user_id: "UBOTH", role: "reporter")

    get fd_members_path

    row = css_select("tr").find { |tr| tr.to_s.include?("UBOTH") }
    numbers = row.css("td.col-num").map(&:text).map(&:strip)
    assert_equal %w[1 1 0], numbers
  end

  test "the six views are offered with counts, the current one marked" do
    get fd_members_path

    assert_select ".views .view", 5
    assert_select ".view[aria-current]", text: /Has a history/
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

  test "a facet turns the view off, as on the queue" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path(priors: "2")

    assert_select ".view[aria-current]", 0
    assert_select ".facet-set.on .facet", text: /Priors\s*2 or more/
  end

  test "everyone reaches past the working set" do
    get fd_members_path(view: "everyone")

    assert_select ".card-title", text: "Everyone"
    assert_operator Fd::MemberQuery.new({ "view" => "everyone" }).total, :>, 100
  end

  test "a long list is paged rather than truncated" do
    get fd_members_path(view: "everyone")

    assert_select "tbody tr", Fd::MemberQuery::LIMIT
    assert_select ".pager-at", text: /Page 1 of \d+/
    assert_select ".pager a", text: "Next"
    assert_select ".pager .is-off", text: "Back", count: 1
    assert_select ".card-sub", text: /1 to #{Fd::MemberQuery::LIMIT} of/
  end

  test "the next page shows the next slice, not the same one again" do
    get fd_members_path(view: "everyone")
    first = css_select("tbody tr .mono").map(&:text)

    get fd_members_path(view: "everyone", page: "2")
    second = css_select("tbody tr .mono").map(&:text)

    assert_equal Fd::MemberQuery::LIMIT, second.size
    assert_empty first & second, "page two must not repeat page one"
    assert_select ".pager-at", text: /Page 2 of/
    assert_select ".card-sub", text: /#{Fd::MemberQuery::LIMIT + 1} to/
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
    assert_select ".card-note", text: /No standing notes on anybody/
  end

  test "the rail offers members alongside cases, and marks which one you are on" do
    get fd_members_path
    assert_select ".rail-nav a[href=?][aria-current=page]", fd_members_path
    assert_select ".rail-nav a[href=?]:not([aria-current])", fd_cases_path

    get fd_cases_path
    assert_select ".rail-nav a[href=?][aria-current=page]", fd_cases_path
  end

  test "each row links to the member record and shows the id" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)
    get fd_members_path

    assert_select "a[href=?]", fd_member_path("UHASONE")
    assert_select ".idline .mono", text: "UHASONE"
  end

  test "an open case shows as a chip on the row" do
    make_case(subject: "UOPEN", opened_at: 2.days.ago)
    get fd_members_path

    assert_select "td .chip.chip-crit", text: "open case"
  end
end
