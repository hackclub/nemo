require "test_helper"

class FdMemberSearchTest < ActionDispatch::IntegrationTest
  setup do
    @me = grant_role!("UME", "community_manager")
    unique_display_names = Fd::Member.live.where.not(display_name: "")
      .group(:display_name).having("count(*) = 1").order(:display_name).pluck(:display_name)
    @member = Fd::Member.live.find_by(display_name: unique_display_names.first)

    unique_real_names = Fd::MemberIdentity.where(user_id: Fd::Member.live.select(:user_id))
      .group(:real_name).having("count(*) = 1").pluck(:real_name)
    @named = Fd::Member.live.joins(:identity)
      .where("fd.member_identity.real_name IN (?)", unique_real_names)
      .where("similarity(lower(coalesce(fd.member.display_name, '')), lower(fd.member_identity.real_name)) < 0.2")
      .where("similarity(lower(coalesce(fd.member.handle, '')), lower(fd.member_identity.real_name)) < 0.2")
      .order(:user_id).first
  end

  def search_members(term)
    get fd_member_search_path(q: term)
    JSON.parse(response.body).fetch("members")
  end

  test "search signed out redirects to login" do
    get fd_member_search_path(q: "ada")
    assert_redirected_to login_path
  end

  test "search by member name returns that member" do
    sign_in_as(@me)
    part = @member.name

    assert_includes search_members(part).map { |row| row["id"] }, @member.user_id
  end

  test "search returns the same members for lower and upper case terms" do
    sign_in_as(@me)
    part = @member.name

    assert_equal search_members(part.downcase).map { |row| row["id"] },
      search_members(part.upcase).map { |row| row["id"] }
  end

  test "search by full member id returns exactly that member" do
    sign_in_as(@me)
    results = search_members(@member.user_id)

    assert_equal 1, results.size
    assert_equal @member.user_id, results.first["id"]
  end

  test "search by lowercase member id returns that member" do
    sign_in_as(@me)
    assert_equal @member.user_id, search_members(@member.user_id.downcase).first["id"]
  end

  test "search with one character or an empty term returns no members" do
    sign_in_as(@me)
    assert_empty search_members("a")
    assert_empty search_members("")
  end

  test "search result includes name and a one character initial" do
    sign_in_as(@me)
    row = search_members(@member.name).find { |result| result["id"] == @member.user_id }

    assert_equal @member.name, row["name"]
    assert_equal @member.initial, row["initial"]
    assert_equal 1, row["initial"].length
  end

  test "search treats percent signs as literals and returns no members" do
    sign_in_as(@me)
    assert_empty search_members("%%%")
  end

  test "search results for a and an total at most Fd::Member::LIMIT" do
    sign_in_as(@me)
    assert_operator search_members("a").size + search_members("an").size, :<=, Fd::Member::LIMIT
  end

  test "search by name excludes deleted and bot members and id lookup finds them" do
    sign_in_as(@me)
    hidden = Fd::Member.where(is_deleted: true).or(Fd::Member.where(is_bot: true)).first
    skip "the corpus has no deleted or bot member" if hidden.nil?

    assert_not_includes search_members(hidden.name).map { |row| row["id"] }, hidden.user_id
    assert_equal hidden.user_id, search_members(hidden.user_id).first["id"],
      "id lookup did not return the deleted or bot member"
  end

  test "search by real name returns that member" do
    sign_in_as(@me)
    name = @named.identity.real_name.downcase

    assert_includes search_members(name).map { |row| row["id"] }, @named.user_id
  end

  test "search by email returns that member" do
    sign_in_as(@me)

    assert_includes search_members(@named.identity.email).map { |row| row["id"] }, @named.user_id
  end

  test "search by real name or email writes no AccessLog row" do
    sign_in_as(@me)
    before = AccessLog.count

    search_members(@named.identity.real_name.downcase)
    search_members(@named.identity.email)

    assert_equal before, AccessLog.count,
      "AccessLog count changed after identity search"
  end

  test "search by real name without identity.read does not return that member" do
    firefighter = grant_role!("UFF2", "firefighter")
    override_capability!("firefighter", "identity.read", false, by: "UME")
    name = @named.identity.real_name.downcase

    sign_in_as(firefighter)

    assert_not_includes search_members(name).map { |row| row["id"] }, @named.user_id
  end

  test "search by member name without identity.read returns that member and no AccessLog row" do
    firefighter = grant_role!("UFF3", "firefighter")
    override_capability!("firefighter", "identity.read", false, by: "UME")
    before = AccessLog.count

    sign_in_as(firefighter)

    assert_includes search_members(@member.name).map { |row| row["id"] }, @member.user_id
    assert_equal before, AccessLog.count
  end
  test "suggest_sql excludes roster aggregates" do
    sql = Fd::MemberFinder.new("dra", actor: @me).suggest_sql(8)

    assert_not_includes sql, "case_participants", "suggest_sql references case_participants"
    assert_not_includes sql, "fd.actions"
    assert_not_includes sql, "notes"
    assert_not_includes sql, "count("
  end

  test "suggest_sql with case_id filters participant.case_id and excludes aggregates" do
    sql = Fd::MemberFinder.new("dra", actor: @me).suggest_sql(8, case_id: 7)

    assert_includes sql, "participant.case_id = 7"
    assert_not_includes sql, "count(", "suggest_sql contains count("
    assert_not_includes sql, "fd.actions"
  end

  test "search with case_id returns the same members with the case subject first" do
    sign_in_as(@me)
    kase = make_case(subject: @member.user_id)

    get fd_member_search_path(q: @member.name, case_id: kase.id)
    on_case = JSON.parse(response.body).fetch("members").map { |row| row["id"] }

    assert_equal search_members(@member.name).map { |row| row["id"] }.sort, on_case.sort
    assert_equal @member.user_id, on_case.first
  end

  test "search with a two character term returns no members and MIN_TERM is 3" do
    sign_in_as(@me)

    assert_empty search_members("dr"), "two character term returned members"
    assert_equal 3, Fd::Member::MIN_TERM
  end
end
