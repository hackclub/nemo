require "test_helper"

class Fd::MemberQueryTest < ActiveSupport::TestCase
  def query(params = {})
    Fd::MemberQuery.new(ActionController::Parameters.new(params))
  end

  def named(user_ids)
    shown = Fd::Member.where(user_id: user_ids)
      .pluck(:user_id, :display_name, :handle)
      .to_h { |id, display, handle| [id, (display.presence || handle.presence || id).downcase] }
    user_ids.map { |id| shown.fetch(id, id.downcase) }
  end

  def collate(said)
    said.gsub(/[^a-z0-9]/, "")
  end

  def counting
    counted = 0
    listener = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, load|
      counted += 1 unless load[:name].to_s.in?(%w[SCHEMA TRANSACTION])
    end
    yield
    counted
  ensure
    ActiveSupport::Notifications.unsubscribe(listener)
  end

  setup do
    skip "no members to sort" if Fd::Member.live.count < 4
  end

  test "the two name directions are exact opposites" do
    forward = query("view" => "everyone", "sort" => "name").summary_rows.map(&:user_id)
    backward = query("view" => "everyone", "sort" => "name", "dir" => "asc")
      .summary_rows.map(&:user_id)

    assert_equal forward.reverse, backward,
      "one direction must be the other read backwards"
    assert_operator forward.size, :>, 1
  end

  test "the name sort groups people by the name they show, not their id" do
    shown = named(query("view" => "everyone", "sort" => "name").rows.map(&:user_id))

    assert_equal shown, shown.sort { |a, b| collate(a) <=> collate(b) },
      "the page is not in the order the database collates names"
  end

  test "a page is the matching slice of the whole ordering" do
    asked = { "view" => "everyone", "sort" => "name" }
    whole = query(asked).summary_rows.map(&:user_id)

    assert_equal whole.first(Fd::MemberQuery::LIMIT), query(asked).rows.map(&:user_id)
    assert_equal whole.slice(Fd::MemberQuery::LIMIT, Fd::MemberQuery::LIMIT),
      query(asked.merge("page" => "2")).rows.map(&:user_id)
  end

  test "a page costs the same whether it is the first or a later one" do
    first = counting { query("view" => "everyone").rows }
    later = counting { query("view" => "everyone", "page" => "3").rows }

    assert_equal first, later, "a later page must not walk further than the first"
    assert_operator first, :<=, 2, "one count and one page, not a walk of the whole roster"
  end

  test "a page holds at most one page worth of people" do
    assert_operator query("view" => "everyone").rows.size, :<=, Fd::MemberQuery::LIMIT
  end

  test "the roster counts everybody the views claim" do
    counts = Fd::MemberQuery.view_counts

    assert_equal counts["everyone"], query("view" => "everyone").total
    assert_equal counts["open"], query("view" => "open").total
    assert_equal counts["notes"], query("view" => "notes").total
  end
end
