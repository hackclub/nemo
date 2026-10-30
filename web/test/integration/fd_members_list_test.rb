require "test_helper"

class FdMembersListTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    sign_in_as(@me)
  end

  def query(**filters)
    Fd::MemberQuery.new(filters.transform_keys(&:to_s), actor: @me)
  end

  def user_ids(**filters)
    query(**filters).rows.map(&:user_id)
  end

  def listed?(user_id, **filters)
    user_ids(**filters).include?(user_id)
  end

  def row_for(user_id, **filters)
    query(**filters).rows.find { |row| row.user_id == user_id }
  end

  def act_on(kase, target:, **attrs)
    Fd::Action.create!({ case_id: kase.id, type_key: "warning", target_user_id: target,
                         decided_by: "UFF1", performed_by: "UFF1" }.merge(attrs))
  end

  test "members index after logout redirects to login" do
    delete logout_path
    get fd_members_path
    assert_redirected_to login_path
  end

  test "member query defaults to everyone view and search finds subject" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert_equal "everyone", Fd::MemberQuery.new({}).view
    assert listed?("UHASONE", view: "history")
    assert_equal ["UHASONE"], user_ids(q: "UHASONE"), "search finds subject under everyone view"
  end

  test "member query history view lists case subjects and excludes other members" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert listed?("UHASONE", view: "history")
    assert_not listed?(Fd::Member.live.where.not(user_id: "UHASONE").first.user_id, view: "history"),
      "history view excludes members without cases"
  end

  test "member query history view lists case participant with zero actions" do
    other_case = make_case(subject: "USOMEBODY", opened_at: 3.days.ago)
    other_case.participants.create!(user_id: "UWATCHER", role: "reporter")

    assert listed?("UWATCHER", view: "history"), "history view lists participants who are not subjects"
    assert_equal 0, row_for("UWATCHER", view: "history").actions
  end

  def numbers_for(user_id)
    row = row_for(user_id, view: "history")
    [row.cases, row.actions]
  end

  test "member query row counts subject and participant cases and actions separately" do
    make_case(subject: "UBOTH", opened_at: 5.days.ago)
    other_case = make_case(subject: "USOMEBODY", opened_at: 3.days.ago)
    other_case.participants.create!(user_id: "UBOTH", role: "reporter")

    assert_equal [2, 0], numbers_for("UBOTH"),
      "subject of one case and participant in another counts two cases and no actions"
  end

  test "member query row counts case once when subject is also participant" do
    self_reported_case = make_case(subject: "UTWICE", opened_at: 5.days.ago)
    self_reported_case.participants.create!(user_id: "UTWICE", role: "reporter")

    assert_equal [1, 0], numbers_for("UTWICE"),
      "subject who is also participant counts one case"
  end

  def create_shush(subject, **over)
    Fd::MemberGuard.create!({ kind: "shush", subject_id: subject, opened_by: "UME",
                              reason: "being awful",
                              expires_at: 5.days.from_now }.merge(over))
  end

  test "member query force view lists live guards and excludes lifted guards and actions" do
    create_shush "ULIVE"
    create_shush "UENDLESS", expires_at: nil
    create_shush "ULIFTED", state: "lifted", lifted_at: 1.day.ago, lifted_by: "UME"

    shush_case = make_case(subject: "ULOGGED", opened_at: 9.days.ago)
    act_on shush_case, target: "ULOGGED", type_key: "shush", expires_at: 5.days.from_now

    assert listed?("ULIVE", view: "force")
    assert listed?("UENDLESS", view: "force"), "guard without expires_at is in force"
    assert_not listed?("ULIFTED", view: "force"), "lifted guard is not in force"
    assert_not listed?("ULOGGED", view: "force"),
      "action without guard is not in force"
  end

  test "member query open view lists only members with an open case" do
    make_case(subject: "UOPEN", opened_at: 2.days.ago)
    make_case(subject: "UCLOSED", opened_at: 9.days.ago, resolved_at: 1.day.ago,
      resolution: "no_action")

    assert listed?("UOPEN", view: "open")
    assert_not listed?("UCLOSED", view: "open")
  end

  test "member query priors view lists members with two action_taken cases only" do
    action_taken_case = make_case(subject: "UPRIORS", opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "action_taken")
    act_on action_taken_case, target: "UPRIORS"
    second = make_case(subject: "UPRIORS", opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "action_taken")
    act_on second, target: "UPRIORS"

    make_case(subject: "UNOACTION", opened_at: 40.days.ago, resolved_at: 30.days.ago,
      resolution: "no_action")
    make_case(subject: "UNOACTION", opened_at: 20.days.ago, resolved_at: 10.days.ago,
      resolution: "no_action")

    assert listed?("UPRIORS", view: "priors")
    assert_not listed?("UNOACTION", view: "priors"), "resolved cases without actions are not priors"
  end

  test "member query with priors facet has no view and no current tab" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert_nil query(priors: "2").view
    assert query(priors: "2").views.none?(&:current)
  end

  test "member query everyone view total exceeds 100" do
    assert_operator Fd::MemberQuery.new({ "view" => "everyone" }).total, :>, 100
  end

  test "member query everyone view returns LIMIT rows and several pages" do
    everyone_query = query(view: "everyone")

    assert_equal Fd::MemberQuery::LIMIT, everyone_query.rows.size
    assert_equal 1, everyone_query.page
    assert_operator everyone_query.pages, :>, 1
  end

  test "member query page 2 returns rows different from page 1" do
    first = user_ids(view: "everyone")
    second = user_ids(view: "everyone", page: "2")

    assert_equal Fd::MemberQuery::LIMIT, second.size
    assert_empty first & second, "page two must not repeat page one"
    assert_equal 2, query(view: "everyone", page: "2").page
  end

  test "member query page past the end clamps to the last page" do
    out_of_range_query = query(view: "everyone", page: "99999")

    assert_equal out_of_range_query.pages, out_of_range_query.page
    assert_not_empty out_of_range_query.rows
  end

  test "member query with negative page uses page 1" do
    assert_equal 1, query(view: "everyone", page: "-3").page
  end

  test "member query facet_params drops page param" do
    assert_equal 3, query(view: "everyone", page: "3").page
    assert_not_includes Fd::MemberQuery.new({ "view" => "everyone", "page" => "3" })
      .facet_params("priors" => "2").keys, "page"
  end

  test "member query with priors facet has one page when total is within LIMIT" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert_operator Fd::MemberQuery.new({ "priors" => "2" }).total, :<=, Fd::MemberQuery::LIMIT
    assert_equal 1, query(priors: "2").pages
  end

  test "member query notes view without standing notes has no rows and an empty_note" do
    Fd::Note.standing.update_all(deleted_at: Time.current, deleted_by: "UME")

    assert_empty user_ids(view: "notes")
    assert_match(/No standing notes/, query(view: "notes").empty_note)
  end

  test "member query with q returns the matching user" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert_equal ["UHASONE"], user_ids(q: "UHASONE")
  end

  test "member query with leading at sign and lower case q lists member" do
    make_case(subject: "UHASONE", opened_at: 2.days.ago)

    assert listed?("UHASONE", q: "@uhasone"), "the search is case insensitive and tolerates the @"
  end

  test "member query with unmatched q returns no rows" do
    assert_empty user_ids(q: "UNOSUCHPERSON")
  end

  test "member query with handle q ranks the exact handle match first" do
    handle = Fd::Member.live.where.not(handle: [nil, ""]).where("length(handle) >= 4")
      .group(:handle).having("count(*) = 1").order(Arel.sql("min(user_id)")).limit(1).pluck(:handle).first
    named = handle && Fd::Member.live.find_by(handle: handle)
    skip "corpus has no member with a unique handle" if named.nil?

    assert_equal named.user_id, user_ids(q: named.handle).first
    assert_equal named.user_id, user_ids(q: named.user_id.downcase).first,
      "lower case id is the exact match"
  end

  test "member query page_params and facet_params keep q" do
    query = Fd::MemberQuery.new({ "q" => "UHASONE", "view" => "everyone" })

    assert_equal "UHASONE", query.page_params(2)["q"], "paging must not drop the search"
    assert_equal "UHASONE", query.facet_params("priors" => "2")["q"],
      "narrowing must not drop the search"
  end
end

class FdMembersActivityTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = grant_role!("UME", "community_manager")
  end

  def record_activity!(user_id, post: nil, login: nil)
    member!(user_id)
    as_pipeline("INSERT INTO fd.member_seen (user_id, last_post_at, last_login_at) VALUES (?, ?, ?) " \
                "ON CONFLICT (user_id) DO UPDATE SET last_post_at = EXCLUDED.last_post_at, " \
                "last_login_at = EXCLUDED.last_login_at", user_id, post, login)
    seeded!("fd.member_seen", "user_id", user_id)
  end

  def user_ids(**filters)
    Fd::MemberQuery.new(filters.transform_keys(&:to_s), actor: @me).rows.map(&:user_id)
  end

  test "member query with recent login matches active week and not dormant" do
    record_activity!("UJUSTIN", login: 1.hour.ago)

    assert_includes user_ids(q: "UJUSTIN", active: "week"), "UJUSTIN"
    assert_empty user_ids(q: "UJUSTIN", active: "dormant")
  end

  test "member query with post 12 days ago matches active month and not week" do
    record_activity!("UPOSTED", post: 12.days.ago, login: 200.days.ago)

    assert_includes user_ids(q: "UPOSTED", active: "month"), "UPOSTED"
    assert_empty user_ids(q: "UPOSTED", active: "week")
  end

  test "member query with post and login over 90 days ago matches dormant" do
    record_activity!("UGONE", post: 120.days.ago, login: 95.days.ago)

    assert_includes user_ids(q: "UGONE", active: "dormant"), "UGONE"
  end
end

class FdMembersSearchTest < ActionDispatch::IntegrationTest
  include SeedsPipelineTables

  setup do
    @me = grant_role!("UME", "community_manager")
  end

  def named!(user_id, display_name, deleted: false)
    as_pipeline("INSERT INTO fd.member (user_id, handle, display_name, is_deleted) VALUES (?, ?, ?, ?) " \
                "ON CONFLICT (user_id) DO UPDATE SET display_name = EXCLUDED.display_name, " \
                "is_deleted = EXCLUDED.is_deleted", user_id, user_id.downcase, display_name, deleted)
    seeded!("fd.member", "user_id", user_id)
  end

  def query(**filters)
    Fd::MemberQuery.new(filters.transform_keys(&:to_s), actor: @me)
  end

  test "member query with q returns Fd::MemberFinder ids in order and total" do
    named!("U0RSTA1", "Quorvex Ombrine")
    named!("U0RSTA2", "Ombrine Quorvexa")
    ranked = Fd::MemberFinder.new("quorvex ombrine", actor: @me).find(limit: 50)

    assert_equal ranked.ids, query(q: "quorvex ombrine").rows.map(&:user_id)
    assert_equal ranked.total, query(q: "quorvex ombrine").total
  end

  test "member query with pasted mention lists deleted member" do
    named!("U0RSTGONE1", "Quorvex Gone", deleted: true)

    assert_equal ["U0RSTGONE1"], query(q: "<@U0RSTGONE1>").rows.map(&:user_id)
  end

  test "member query with q paginates matches by 50" do
    55.times { |n| named!(format("U0RSTP%03d", n), "Quorvexpage #{n}") }

    first = query(q: "quorvexpage").rows.map(&:user_id)
    second = query(q: "quorvexpage", page: "2").rows.map(&:user_id)
    assert_equal 50, first.size
    assert_equal 5, second.size
    assert_empty first & second
  end

  test "member query with q and history view lists only members with cases" do
    named!("U0RSTF1", "Quorvex Facet")
    named!("U0RSTF2", "Quorvex Facetwo")
    make_case(subject: "U0RSTF2", opened_at: 2.days.ago)

    assert_equal ["U0RSTF2"], query(q: "quorvex", view: "history").rows.map(&:user_id)
    assert_equal 1, query(q: "quorvex", view: "history").total
  end
end
