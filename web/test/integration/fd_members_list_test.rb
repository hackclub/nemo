require "test_helper"

class FdMembersListTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def query(**asked)
    Fd::MemberQuery.new(asked.transform_keys(&:to_s), actor: @me)
  end

  def shown(**asked)
    query(**asked).rows.map(&:user_id)
  end

  def listed?(user_id, **asked)
    shown(**asked).include?(user_id)
  end

  def row_for(user_id, **asked)
    query(**asked).rows.find { |row| row.user_id == user_id }
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

    assert_equal "everyone", Fd::MemberQuery.new({}).view
    assert listed?("UHASONE")
  end

  test "the history view narrows to people conduct work has touched" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert listed?("UHASONE", view: "history")
    assert_not listed?(Fd::Member.live.where.not(user_id: "UHASONE").first.user_id, view: "history"),
      "nine thousand quiet members are not the working set"
  end

  test "somebody only ever logged in another case still belongs here" do
    theirs = make_case(subject: "USOMEBODY", opened_at: 3.days.ago)
    theirs.participants.create!(user_id: "UWATCHER", role: "involved", detail: "aimed at them")

    assert listed?("UWATCHER"), "a page of subjects would hide the people conduct work is for"
    assert_equal 0, row_for("UWATCHER").actions
  end

  def numbers_for(user_id)
    row = row_for(user_id, view: "history")
    [row.cases, row.actions]
  end

  test "a row counts every case that named them, and the actions apart" do
    make_case(subject: "UBOTH", opened_at: 5.days.ago)
    theirs = make_case(subject: "USOMEBODY", opened_at: 3.days.ago)
    theirs.participants.create!(user_id: "UBOTH", role: "reporter")

    assert_equal [2, 0], numbers_for("UBOTH"),
      "subject of one and logged in another is two cases, no actions"
  end

  test "one case that names somebody twice is still one case" do
    both = make_case(subject: "UTWICE", opened_at: 5.days.ago)
    both.participants.create!(user_id: "UTWICE", role: "reporter")

    assert_equal [1, 0], numbers_for("UTWICE"),
      "reporting the case you are the subject of does not make it two cases"
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

    assert listed?("ULIVE", view: "force")
    assert_not listed?("ULAPSED", view: "force"), "its due date has passed"
    assert_not listed?("UWARNED", view: "force"), "a warning has no due date to reach"
    assert_not listed?("ULIFTED", view: "force"), "it was reversed"
  end

  test "the open case view keeps only people with one open" do
    make_case(subject: "UOPEN", opened_at: 2.days.ago)
    make_case(subject: "UCLOSED", opened_at: 9.days.ago, resolved_at: 1.day.ago,
      resolution: "no_action")

    assert listed?("UOPEN", view: "open")
    assert_not listed?("UCLOSED", view: "open")
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

    assert listed?("UPRIORS", view: "priors")
    assert_not listed?("UNOACTION", view: "priors"), "two resolved cases with no action are not two priors"
  end

  test "a facet narrows outside the tabs, and marks none of them current" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert_nil query(priors: "2").view
    assert query(priors: "2").views.none?(&:current)
  end

  test "everyone reaches past the working set" do
    assert_operator Fd::MemberQuery.new({ "view" => "everyone" }).total, :>, 100
  end

  test "a long list is paged rather than truncated" do
    everyone = query(view: "everyone")

    assert_equal Fd::MemberQuery::LIMIT, everyone.rows.size
    assert_equal 1, everyone.page
    assert_operator everyone.pages, :>, 1
  end

  test "the next page shows the next slice, not the same one again" do
    first = shown(view: "everyone")
    second = shown(view: "everyone", page: "2")

    assert_equal Fd::MemberQuery::LIMIT, second.size
    assert_empty first & second, "page two must not repeat page one"
    assert_equal 2, query(view: "everyone", page: "2").page
  end

  test "a page past the end lands on the last page rather than an empty table" do
    far = query(view: "everyone", page: "99999")

    assert_equal far.pages, far.page
    assert_not_empty far.rows
  end

  test "a nonsense page number is treated as the first" do
    assert_equal 1, query(view: "everyone", page: "-3").page
  end

  test "narrowing resets to the first page" do
    assert_equal 3, query(view: "everyone", page: "3").page
    assert_not_includes Fd::MemberQuery.new({ "view" => "everyone", "page" => "3" })
      .facet_params("priors" => "2").keys, "page"
  end

  test "a short list has one page" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert_operator Fd::MemberQuery.new({ "priors" => "2" }).total, :<=, Fd::MemberQuery::LIMIT
    assert_equal 1, query(priors: "2").pages
  end

  test "a view that matches nothing has no rows and says which nothing it is" do
    Fd::Note.standing.update_all(deleted_at: Time.current, deleted_by: "UME")

    assert_empty shown(view: "notes")
    assert_match(/No standing notes on anybody/, query(view: "notes").empty_note)
  end

  test "searching narrows the roster to the people asked for" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert_equal ["UHASONE"], shown(q: "UHASONE")
  end

  test "a leading at sign is ignored, so pasting a handle works" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert listed?("UHASONE", q: "@uhasone"), "the search is case insensitive and tolerates the @"
  end

  test "a search that matches nobody says so rather than showing everybody" do
    assert_empty shown(q: "UNOSUCHPERSON")
  end

  test "an exact handle match comes before anyone who merely contains it" do
    named = Fd::Member.live.where.not(handle: [nil, ""]).where("length(handle) >= 4")
      .order(:user_id).first
    skip "the corpus has no member with a handle" if named.nil?

    assert_equal named.user_id, shown(q: named.handle).first
    assert_equal named.user_id, shown(q: named.user_id.downcase).first,
      "an id typed in any case is still the exact match"
  end

  test "the search survives paging and view links" do
    query = Fd::MemberQuery.new({ "q" => "UHASONE", "view" => "everyone" })

    assert_equal "UHASONE", query.page_params(2)["q"], "paging must not drop the search"
    assert_equal "UHASONE", query.facet_params("priors" => "2")["q"],
      "narrowing must not drop the search"
  end

end
