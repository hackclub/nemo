require "test_helper"

class Fd::MemberQueryTest < ActiveSupport::TestCase
  def query(params = {})
    Fd::MemberQuery.new(ActionController::Parameters.new(params))
  end

  def rows(user_ids)
    user_ids.map { |id| Fd::MemberQuery::Row.new(user_id: id) }
  end

  def by_name(user_ids)
    query.send(:by_name, rows(user_ids)).map(&:user_id)
  end

  setup do
    @members = Fd::Member.where.not(display_name: nil).order(:user_id).limit(8).to_a
    skip "no members to sort" if @members.size < 4
    @ids = @members.map(&:user_id)
  end

  test "the roster sorts by the name the member model reports" do
    expected = @members
      .sort_by { |m| [m.name.sub(/\A@/, "").downcase, m.user_id] }
      .map(&:user_id)

    assert_equal expected, by_name(@ids.shuffle)
  end

  test "the order does not depend on the order it was handed" do
    assert_equal by_name(@ids), by_name(@ids.reverse)
  end

  test "somebody with no member row still sorts, and not to the front" do
    found = by_name(@ids + ["ZZUNKNOWN"])

    assert_equal @ids.size + 1, found.size
    assert_not_equal "ZZUNKNOWN", found.first, "an unknown member used to sort above everyone"
    assert_equal "ZZUNKNOWN", found.last, "@ZZUNKNOWN sorts under its own id"
  end

  test "naming the whole roster takes one query, whatever its size" do
    many = @ids + Array.new(40) { |n| format("ZZBULK%03d", n) }

    counted = 0
    listener = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, load|
      counted += 1 unless load[:name].to_s.in?(%w[SCHEMA TRANSACTION])
    end
    by_name(many)
    ActiveSupport::Notifications.unsubscribe(listener)

    assert_equal 1, counted, "one bulk lookup, not one per member"
  end
end
