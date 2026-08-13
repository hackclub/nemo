require "test_helper"

class FdMemberSearchTest < ActionDispatch::IntegrationTest
  setup do
    @me = Staff.create!(user_id: "UME", community_manager: true)
    lone = Fd::Member.live.where.not(display_name: "")
      .group(:display_name).having("count(*) = 1").order(:display_name).pluck(:display_name)
    @member = Fd::Member.live.find_by(display_name: lone.first)
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
end
