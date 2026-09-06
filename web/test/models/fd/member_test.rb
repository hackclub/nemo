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
end
