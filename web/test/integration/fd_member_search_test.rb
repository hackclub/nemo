require "test_helper"

class FdMemberSearchTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UME", "community_manager")
    lone = Fd::Member.live.where.not(display_name: "")
      .group(:display_name).having("count(*) = 1").order(:display_name).pluck(:display_name)
    @member = Fd::Member.live.find_by(display_name: lone.first)

    lone_name = Fd::MemberIdentity.where(user_id: Fd::Member.live.select(:user_id))
      .group(:real_name).having("count(*) = 1").pluck(:real_name)
    @named = Fd::Member.live.joins(:identity)
      .where("fd.member_identity.real_name = ?", lone_name.first).first
  end

  def look(term)
    get fd_member_search_path(q: term)
    JSON.parse(response.body).fetch("members")
  end

  test "a signed out visitor cannot search members" do
    get fd_member_search_path(q: "ada")
    assert_redirected_to login_path
  end

  test "searching by part of a name finds them" do
    sign_in_as(@me)
    part = @member.name

    assert_includes look(part).map { |row| row["id"] }, @member.user_id
  end

  test "search is case blind, because nobody types the way the profile was written" do
    sign_in_as(@me)
    part = @member.name

    assert_equal look(part.downcase).map { |row| row["id"] },
      look(part.upcase).map { |row| row["id"] }
  end

  test "a whole member id is looked up directly, so a paste always works" do
    sign_in_as(@me)
    found = look(@member.user_id)

    assert_equal 1, found.size
    assert_equal @member.user_id, found.first["id"]
  end

  test "a lowercase pasted id still resolves" do
    sign_in_as(@me)
    assert_equal @member.user_id, look(@member.user_id.downcase).first["id"]
  end

  test "one letter is not a search, so the list stays empty" do
    sign_in_as(@me)
    assert_empty look("a")
    assert_empty look("")
  end

  test "results carry what the token needs to draw itself" do
    sign_in_as(@me)
    row = look(@member.name).find { |found| found["id"] == @member.user_id }

    assert_equal @member.name, row["name"]
    assert_equal @member.initial, row["initial"]
    assert_equal 1, row["initial"].length
  end

  test "a percent sign is a character to search for, not a wildcard" do
    sign_in_as(@me)
    assert_empty look("%%%")
  end

  test "the list is capped, so one common syllable cannot return the workspace" do
    sign_in_as(@me)
    assert_operator look("a").size + look("an").size, :<=, Fd::Member::LIMIT
  end

  test "deleted and bot members stay out of the name search" do
    sign_in_as(@me)
    hidden = Fd::Member.where(is_deleted: true).or(Fd::Member.where(is_bot: true)).first
    skip "the corpus has no deleted or bot member" if hidden.nil?

    assert_not_includes look(hidden.name).map { |row| row["id"] }, hidden.user_id
    assert_equal hidden.user_id, look(hidden.user_id).first["id"],
      "a direct id lookup still finds them, since a case may name one"
  end

  test "a real name finds them, since it is not just a handle search" do
    sign_in_as(@me)
    name = @named.identity.real_name.downcase

    assert_includes look(name).map { |row| row["id"] }, @named.user_id
  end

  test "an email finds the person it belongs to" do
    sign_in_as(@me)

    assert_includes look(@named.identity.email).map { |row| row["id"] }, @named.user_id
  end

  test "a real name or email match is logged like an identity read" do
    sign_in_as(@me)
    before = AccessLog.where(field_class: "identity_search").pluck(:id)

    look(@named.identity.real_name.downcase)

    fresh = AccessLog.where(field_class: "identity_search").where.not(id: before)
    assert_operator fresh.count, :>, 0
    assert_includes fresh.pluck(:subject_user_id), @named.user_id
    assert fresh.pluck(:actor_id).all? { |id| id == @me.user_id }
  end

  test "somebody whose role does not carry identity.read cannot find a person by real name" do
    them = hold_role!("UFF2", "firefighter")
    move_capability!("firefighter", "identity.read", false, by: "UME")
    name = @named.identity.real_name.downcase

    sign_in_as(them)

    assert_not_includes look(name).map { |row| row["id"] }, @named.user_id
  end

  test "somebody without identity.read still finds people by handle or display name, and it is not logged as an identity read" do
    them = hold_role!("UFF3", "firefighter")
    move_capability!("firefighter", "identity.read", false, by: "UME")
    before = AccessLog.count

    sign_in_as(them)

    assert_includes look(@member.name).map { |row| row["id"] }, @member.user_id
    assert_equal before, AccessLog.count
  end
end
