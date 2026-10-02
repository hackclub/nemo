require "test_helper"

class ChannelsFilterTest < ActionDispatch::IntegrationTest
  setup do
    @me = hold_role!("UCHAN", "analytics")
    sign_in_as(@me)
  end

  def ask(**params)
    get channels_path(params)
  end

  def value_for(field, op)
    return "a" if field.kind == :text
    return "30" if field.kind == :date && Channels::Filter::DAY_COUNT_OPS.include?(op)
    return "2026-01-01" if field.kind == :date

    "1"
  end

  def every_field_and_op
    Channels::Filter::FIELDS.flat_map do |field|
      field.ops.keys.map { |op| [field, op] }
    end
  end

  test "every filterable field and operator builds SQL the controller's joins can answer" do
    pairs = every_field_and_op
    refute_empty pairs, "no field left to filter on, so this checks nothing"

    broken = pairs.reject do |field, op|
      arity = Channels::Filter::OPS.fetch(field.kind).fetch(op).last
      values = Array.new(arity) { value_for(field, op) }
      ask(c: { "0" => { "f" => field.key, "op" => op, "v" => values } })
      response.status == 200
    end

    assert_empty broken.map { |field, op| "#{field.key} #{op} => #{response.status}" }
  end

  test "a date filter given the wrong shape of value drops the condition instead of breaking" do
    ask(c: { "0" => { "f" => "created", "op" => "within", "v" => ["2026-01-01"] } })

    assert_response :success
  end

  test "the rolled window joins its own alias without colliding with the mart joins" do
    ask(days: Channels::Window::PRESETS.first)

    assert_response :success
  end

  test "every offered sort names a column the joins provide" do
    refute_empty ChannelsController::SORT_SQL

    broken = ChannelsController::SORT_SQL.keys.reject do |key|
      ask(sort: key, direction: "asc")
      response.status == 200
    end

    assert_empty broken, "these sorts broke: #{broken.join(', ')}"
  end
end
