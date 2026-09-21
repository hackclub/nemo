require "test_helper"

class Fd::MemberTest < ActiveSupport::TestCase
  test "the picker puts a member whose display name is the term before anyone who merely contains it" do
    named = Fd::Member.live.where.not(display_name: [nil, ""]).where("length(display_name) >= 4")
      .where("display_name !~ '[%_]'").order(:user_id).first
    skip "the corpus has no member with a display name" if named.nil?

    first = Fd::Member.search(named.display_name).first
    assert_equal named.display_name.downcase, first.display_name.to_s.downcase
  end

  test "an exact handle outranks a name that only starts with the term" do
    named = Fd::Member.live.where.not(handle: [nil, ""]).where("length(handle) >= 4")
      .where("handle !~ '[%_]'").order(:user_id).first
    skip "the corpus has no member with a handle" if named.nil?

    assert_equal named.user_id, Fd::Member.search(named.handle).first.user_id
  end

  test "a closer match never sits below a looser one, and equals are sorted by who talks" do
    stem = crowded_stem
    skip "the corpus has no name three members share" if stem.nil?
    rows = ranked(stem)
    assert_operator rows.size, :>, 1

    places = rows.map { |row| row[:place] }
    assert_equal places.sort, places, "a closer match must never sit below a looser one"

    equals = rows.each_cons(2).select { |above, below| above[:place] == below[:place] }
    skip "the corpus has no two equally close matches" if equals.empty?
    assert equals.any? { |above, below| above[:talked].to_i != below[:talked].to_i },
      "the corpus must hold equally close matches who differ in how much they talk"
    equals.each do |above, below|
      assert_operator above[:talked].to_i, :>=, below[:talked].to_i
    end
  end

  test "among equally close matches the one already on the case is meant" do
    stem = crowded_stem
    skip "the corpus has no name three members share" if stem.nil?
    rows = ranked(stem)
    first = rows.first
    party = rows.drop(1).find { |row| row[:place] == first[:place] }
    skip "the corpus has no two equally close matches" if party.nil?

    kase = make_case(subject: party.user_id)

    assert_equal party.user_id, ranked(stem, case_id: kase.id).first.user_id
    assert_equal first.user_id, ranked(stem).first.user_id,
      "off the case the order is the plain one"
  end

  test "the shortlist is cut by how much they talk, before the alphabet" do
    sql = Fd::Member.search(crowded_stem || "dra", live_only: true).to_sql
    shortlist = sql[sql.index("JOIN (")..sql.index(") pick ON")]

    assert_operator shortlist.index("spoke.messages_posted DESC NULLS LAST"), :<,
      shortlist.index("lower(coalesce(nullif(fd.member.display_name"),
      "cut the shortlist by name and a busy member falls off it before ranking begins"
    assert_includes shortlist, "LIMIT #{Fd::Member::SHORTLIST}"
  end

  test "being on the case sorts under the match, not over it" do
    sql = Fd::Member.search("dra", live_only: true, case_id: 7).to_sql
    order = sql[sql.rindex("ORDER BY")..]

    assert_operator order.index("pick.place"), :<, order.index("party.case_id = 7")
    assert_operator order.index("party.case_id = 7"), :<, order.index("pick.talked")
  end

  private

  def crowded_stem
    Fd::Member.live.where.not(display_name: [nil, ""]).pluck(:display_name)
      .map { |name| name.downcase[0, Fd::Member::MIN_TERM] }.tally
      .select { |stem, seen| stem.length == Fd::Member::MIN_TERM && seen >= 3 }
      .max_by { |_, seen| seen }&.first
  end

  def ranked(term, **opts)
    Fd::Member.search(term, live_only: true, **opts)
      .select(Arel.sql("fd.member.user_id, pick.place, pick.talked")).to_a
  end
end
