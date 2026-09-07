require "test_helper"

class Channels::FilterTest < ActiveSupport::TestCase
  def build(rows, match: nil)
    Channels::Filter.new(rows: rows, match: match)
  end

  test "a number condition binds its value instead of interpolating it" do
    f = build([{ "f" => "members", "op" => "gt", "v" => ["1000"] }])
    sql, *binds = f.clause

    assert_equal "r.total_members > ?", sql
    assert_equal [1000], binds
  end

  test "a value that is not a number is dropped rather than reaching the query" do
    %w[1000);DROP 1e9 abc " 12abc].each do |bad|
      f = build([{ "f" => "members", "op" => "gt", "v" => [bad] }])
      assert_empty f.conditions, "#{bad.inspect} must not survive coercion"
      assert_nil f.clause
    end
  end

  test "an unknown field or operator is ignored" do
    assert_empty build([{ "f" => "total_members", "op" => "gt", "v" => ["1"] }]).conditions
    assert_empty build([{ "f" => "members", "op" => "drop", "v" => ["1"] }]).conditions
    assert_empty build([{ "f" => "members", "op" => "contains", "v" => ["1"] }]).conditions,
      "an operator from another kind must not apply"
  end

  test "between takes two values and orders them, in the sql and in the label" do
    f = build([{ "f" => "members", "op" => "between", "v" => %w[900 100] }])
    sql, *binds = f.clause

    assert_equal "r.total_members BETWEEN ? AND ?", sql
    assert_equal [100, 900], binds
    assert_equal "Members is between 100 and 900", f.conditions.first.label
  end

  test "between with one value is dropped" do
    assert_empty build([{ "f" => "members", "op" => "between", "v" => ["100"] }]).conditions
  end

  test "an operator with no value needs none" do
    f = build([{ "f" => "last_post", "op" => "unset", "v" => [] }])

    assert_equal 1, f.size
    assert_equal ["(r.channel_id IS NOT NULL AND r.last_message_at IS NULL)"], f.clause
  end

  test "like wildcards in a text value are escaped" do
    f = build([{ "f" => "name", "op" => "contains", "v" => ["100%_a"] }])
    _sql, bind = f.clause

    assert_equal "%100\\%\\_a%", bind
  end

  test "match all joins with AND and match any with OR" do
    rows = [
      { "f" => "members", "op" => "gt", "v" => ["10"] },
      { "f" => "posters", "op" => "lt", "v" => ["5"] }
    ]

    assert_includes build(rows).clause.first, " AND "
    assert_includes build(rows, match: "any").clause.first, " OR "
    assert_includes build(rows, match: "sideways").clause.first, " AND "
  end

  test "a relative date bows to an integer count of days" do
    f = build([{ "f" => "last_post", "op" => "within", "v" => ["90"] }])
    sql, *binds = f.clause

    assert_equal "r.last_message_at >= now() - (? || ' days')::interval", sql
    assert_equal [90], binds
  end

  test "an absolute date parses as a date" do
    f = build([{ "f" => "created", "op" => "after", "v" => ["2026-01-31"] }])
    _sql, bind = f.clause

    assert_equal Date.new(2026, 1, 31), bind
  end

  test "conditions are capped" do
    rows = Array.new(30) { { "f" => "members", "op" => "gt", "v" => ["1"] } }

    assert_equal Channels::Filter::MAX_CONDITIONS, build(rows).size
  end

  test "a condition can describe itself" do
    assert_equal "Members is over 10",
      build([{ "f" => "members", "op" => "gt", "v" => ["10"] }]).conditions.first.label
    assert_equal "Share who spoke is between 2% and 10%",
      build([{ "f" => "spoke", "op" => "between", "v" => %w[10 2] }]).conditions.first.label
    assert_equal "Last post is within the last 90 days",
      build([{ "f" => "last_post", "op" => "within", "v" => ["90"] }]).conditions.first.label
  end

  test "from reads conditions keyed by index, which is how the form submits them" do
    params = ActionController::Parameters.new(
      "match" => "all",
      "c" => { "898" => { "f" => "members", "op" => "gt", "v" => ["10000", ""] } }
    )
    f = Channels::Filter.from(params)

    assert_equal 1, f.size, "an index-keyed hash of rows must parse"
    assert_equal ["r.total_members > ?", 10_000], f.clause
  end

  test "from also reads a plain list of conditions" do
    params = ActionController::Parameters.new(
      "c" => [{ "f" => "members", "op" => "lt", "v" => ["5"] }]
    )

    assert_equal ["r.total_members < ?", 5], Channels::Filter.from(params).clause
  end

  test "from with nothing gives no conditions" do
    assert_empty Channels::Filter.from(ActionController::Parameters.new).conditions
  end

  test "a measure override repoints one field and leaves the rest alone" do
    params = ActionController::Parameters.new(
      "c" => { "0" => { "f" => "messages", "op" => "gt", "v" => ["100"] },
               "1" => { "f" => "members", "op" => "gt", "v" => ["10"] } }
    )
    f = Channels::Filter.from(params, measures: { "messages" => "a.range_messages" })

    assert_equal ["a.range_messages > ? AND r.total_members > ?", 100, 10], f.clause
  end

  test "a measure override cannot introduce a field the whitelist does not hold" do
    params = ActionController::Parameters.new(
      "c" => [{ "f" => "spend", "op" => "gt", "v" => ["1"] }]
    )

    assert_empty Channels::Filter.from(params, measures: { "spend" => "1=1" }).conditions
  end

  test "an overridden field still reports itself unset against its own alias" do
    f = Channels::Filter.from(
      ActionController::Parameters.new("c" => [{ "f" => "messages", "op" => "unset", "v" => [] }]),
      measures: { "messages" => "a.range_messages" }
    )

    assert_equal ["a.range_messages IS NULL"], f.clause
  end

  test "every field offers only its own kind of operator" do
    Channels::Filter::FIELDS.each do |field|
      assert Channels::Filter::OPS.key?(field.kind), "#{field.key} has no operator set"
    end
  end
end
